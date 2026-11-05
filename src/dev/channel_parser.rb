# typed: strict
# frozen_string_literal: true

require "dev/lifecycle"
require_relative "builtins/deploy_status_command"
require_relative "command"
require_relative "command_parser"

module Dev
  # Parses the dev.yml `commands: deploy:` entry into Lifecycle::Channel
  # values — the dev.yml boundary for channels, as TargetParser is for
  # targets (dev#192, K5). With targets declared, `deploy` is derived from
  # its children: every child is a **channel** — `targets:` the build
  # patterns it accepts (parsed in the one grammar against the project's
  # targets, so a pattern naming no build fails at load), `run:` its
  # protocol, `desc` and `environment:` as any command's. The entry itself
  # has no body and no other keys to give: a `run:` on `deploy`, a child
  # without `targets:`, a child without a protocol, a child with children
  # of its own are each refused with the fix named.
  #
  # The child's `run:`, `desc`, `environment:` and `hidden` are read by the
  # CommandParser (one reading of a command body), then recast as the
  # channel's publisher; the parser stays lock-free, the reference is the
  # composition root's to bind.
  #
  # Stateless: reusable across manifests, inputs arrive as method arguments.
  class ChannelParser
    extend T::Sig

    # `deploy` carries a `run:` — but it is derived from its channels and
    # has no body of its own.
    class DeployBodyError < ArgumentError; end

    # `deploy` declares no child: nothing to ship to.
    class NoChannelsError < ArgumentError; end

    # A `deploy` child that is not a mapping (a bare string, a list).
    class InvalidChannelError < ArgumentError; end

    # A channel named `help` (the tree reserves the word under every node)
    # or `status` (`dev deploy status` is dev's, beside the channels).
    class ReservedChannelNameError < ArgumentError; end

    # A `deploy` child without `targets:`, or with one that is not a
    # non-empty list of build patterns.
    class ChannelAcceptsError < ArgumentError; end

    # A `deploy` child with neither a `run:` nor a publisher the lock
    # contributes.
    class ChannelProtocolError < ArgumentError; end

    # A `deploy` child with `commands:` of its own: a channel is a leaf.
    class ChannelChildrenError < ArgumentError; end

    DEPLOY = "deploy"
    ACCEPTS_KEY = "targets"
    # Names no channel may take: `help` under every node, `status` for the
    # ledger's own child of `deploy`.
    RESERVED_NAMES = T.let([CommandParser::RESERVED_CHILD_NAME, Builtins::DeployStatusCommand::NAME].freeze, T::Array[String])

    DeployHash = T.type_alias { T::Hash[String, T.untyped] }

    # @param command_parser [CommandParser] reads each child's command body
    sig { params(command_parser: CommandParser).void }
    def initialize(command_parser: CommandParser.new)
      @command_parser = command_parser
    end

    # Whether a raw `commands:` mapping declares a `deploy` child carrying
    # `targets:` — the shape of a channel, which only means something once
    # the project declares targets (the loader refuses it otherwise).
    #
    # @param raw_commands [Object] the `commands` value as YAML delivered it
    # @return [Boolean]
    sig { params(raw_commands: T.untyped).returns(T::Boolean) }
    def channels_declared?(raw_commands)
      return false unless raw_commands.is_a?(Hash)

      deploy = raw_commands[DEPLOY]
      return false unless deploy.is_a?(Hash) && deploy["commands"].is_a?(Hash)

      deploy["commands"].values.any? { |child| child.is_a?(Hash) && child.key?(ACCEPTS_KEY) }
    end

    # Parse the `deploy` entry; absent means no channel declared.
    #
    # @param raw [Object] the `commands: deploy:` value as YAML delivered it
    # @param targets [Array<Lifecycle::Target>] the project's declared targets
    # @return [Hash{String => Lifecycle::Channel}] in declaration order
    # @raise [DeployBodyError]
    # @raise [NoChannelsError]
    # @raise [InvalidChannelError]
    # @raise [ReservedChannelNameError]
    # @raise [ChannelAcceptsError]
    # @raise [ChannelProtocolError]
    # @raise [ChannelChildrenError]
    # @raise [CommandParser::InvalidEnvironmentError]
    # @raise [Lifecycle::BuildPattern::UnknownTargetError] and the grammar's
    #   other errors, for an accept pattern no target admits
    sig { params(raw: T.untyped, targets: T::Array[Lifecycle::Target]).returns(T::Hash[String, Lifecycle::Channel]) }
    def parse_all(raw, targets)
      return {} if raw.nil?

      # A non-mapping `deploy` body has no children to read and surfaces
      # as NoChannelsError under its own name.
      deploy = raw.is_a?(Hash) ? raw : {}
      unless deploy["run"].to_s.empty?
        raise DeployBodyError,
          "command '#{DEPLOY}' declares `run:`, but #{DEPLOY} is derived from its channels — delete the `run:` " \
            "and declare each destination as a child with `targets:` and `run:` (d3mlabs/dev#192)"
      end

      children = deploy["commands"]
      unless children.is_a?(Hash) && !children.empty?
        raise NoChannelsError,
          "command '#{DEPLOY}' declares no channel — add a child per destination under `commands:`, with the builds it " \
            "accepts under `#{ACCEPTS_KEY}:` and its protocol under `run:` (d3mlabs/dev#192)"
      end

      children.to_h do |name, entry|
        name = name.to_s
        if RESERVED_NAMES.include?(name)
          raise ReservedChannelNameError, "command '#{DEPLOY}': '#{name}' is reserved and cannot name a channel"
        end
        unless entry.is_a?(Hash)
          raise InvalidChannelError, "channel '#{DEPLOY} #{name}': expected a mapping (desc, #{ACCEPTS_KEY}, run, environment)"
        end

        [name, parse(name, entry, targets)]
      end
    end

    # Parse one channel entry.
    #
    # @param name [String] the `deploy` child's key
    # @param entry [DeployHash]
    # @param targets [Array<Lifecycle::Target>]
    # @return [Lifecycle::Channel]
    # @raise [ChannelAcceptsError]
    # @raise [ChannelProtocolError]
    # @raise [ChannelChildrenError]
    # @raise [CommandParser::InvalidEnvironmentError]
    sig { params(name: String, entry: DeployHash, targets: T::Array[Lifecycle::Target]).returns(Lifecycle::Channel) }
    def parse(name, entry, targets)
      path = [DEPLOY, name]
      if entry.key?("commands")
        raise ChannelChildrenError, "channel '#{path.join(" ")}' declares `commands:`, but a channel has no subcommands — " \
                                    "each destination is its own `deploy` child"
      end
      if entry["run"].to_s.empty?
        raise ChannelProtocolError,
          "channel '#{path.join(" ")}' has no protocol: declare `run:` (a script shipping `$DEV_ARTIFACT`), or name an " \
            "integration whose publisher knows the endpoint (d3mlabs/dev#422)"
      end

      command = T.cast(@command_parser.parse(path, entry), ProjectCommand)
      Lifecycle::Channel.new(
        name:,
        desc: command.desc,
        accepts: accept_patterns(path, entry[ACCEPTS_KEY], targets),
        publisher: Lifecycle::PublisherSpec::Script.new(command: command.run, environment: command.environment),
      )
    end

    private

    # The `targets:` list as patterns in the one grammar.
    #
    # @param path [Array<String>] the channel's command path, for messages
    # @param raw [Object] the `targets` value as YAML delivered it
    # @param targets [Array<Lifecycle::Target>]
    # @return [Array<Lifecycle::BuildPattern>] in declaration order
    # @raise [ChannelAcceptsError]
    sig { params(path: T::Array[String], raw: T.untyped, targets: T::Array[Lifecycle::Target]).returns(T::Array[Lifecycle::BuildPattern]) }
    def accept_patterns(path, raw, targets)
      unless raw.is_a?(Array) && !raw.empty? && raw.all?(String)
        raise ChannelAcceptsError,
          "channel '#{path.join(" ")}': `#{ACCEPTS_KEY}:` must be a non-empty list of the builds it accepts " \
            "(`<target>[-<platform>[-<config>]]`, an omitted axis meaning any), got #{raw.inspect}"
      end

      raw.map { |pattern| Lifecycle::BuildPattern.parse(pattern, targets) }
    end
  end
end
