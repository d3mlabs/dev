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
  # protocol when it has a script one, `desc` and `environment:` as any
  # command's. A child with no `run:` names the publisher the lock's
  # integration of the same name contributes (dev#422): `targets:` then
  # *configures* that channel, where a `run:` *replaces* its protocol
  # (K1b). The entry itself has no body and no other keys to give: a
  # `run:` on `deploy`, a child without `targets:`, a child with children
  # of its own, an `environment:` with no `run:` to place are each refused
  # with the fix named.
  #
  # The child's `run:`, `desc`, `environment:` and `hidden` are read by the
  # CommandParser (one reading of a command body), then recast as the
  # channel's publisher; the parser stays lock-free — whether the lock
  # contributes the publisher a child names is the composition root's to
  # bind (ChannelBinder), as an `environment:` reference is.
  #
  # A child without `run:` may carry the publisher's **options** under a
  # key of its own name (`steam: { app: 480, depots: … }`, dev#426) — the
  # namespacing an integration builder's target options use (K1). The
  # mapping is handed to the channel as YAML delivered it: its vocabulary
  # is the publisher's, which validates it. Beside a `run:` the key is
  # refused — the script replaced the publisher the options would
  # configure.
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

    # A channel named `help` (the tree reserves the word under every node),
    # `status` (`dev deploy status` is dev's, beside the channels) or
    # `releases` (the store's `.releases/` is where `deploy --release`
    # keeps its downloads, beside the channels' `.<channel>/` scratches).
    class ReservedChannelNameError < ArgumentError; end

    # A `deploy` child without `targets:`, or with one that is not a
    # non-empty list of build patterns.
    class ChannelAcceptsError < ArgumentError; end

    # A `deploy` child with `environment:` but no `run:`: an integration's
    # publisher runs where dev runs, so the key has nothing to place.
    class ChannelEnvironmentError < ArgumentError; end

    # A `deploy` child with `commands:` of its own: a channel is a leaf.
    class ChannelChildrenError < ArgumentError; end

    # A `deploy` child whose publisher options (the mapping under its own
    # name) are not a mapping, or sit beside a `run:` that replaces the
    # publisher they would configure.
    class ChannelOptionsError < ArgumentError; end

    DEPLOY = "deploy"
    ACCEPTS_KEY = "targets"
    RUN_KEY = "run"
    # Names no channel may take: `help` under every node, `status` for the
    # ledger's own child of `deploy`, `releases` for the store's directory
    # of downloaded releases.
    RESERVED_NAMES = T.let(
      [CommandParser::RESERVED_CHILD_NAME, Builtins::DeployStatusCommand::NAME, Lifecycle::Store::RELEASES_DIR].freeze,
      T::Array[String],
    )

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
    # @raise [ChannelEnvironmentError]
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
      unless deploy[RUN_KEY].to_s.empty?
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
    # @raise [ChannelEnvironmentError]
    # @raise [ChannelChildrenError]
    # @raise [ChannelOptionsError]
    # @raise [CommandParser::InvalidEnvironmentError]
    sig { params(name: String, entry: DeployHash, targets: T::Array[Lifecycle::Target]).returns(Lifecycle::Channel) }
    def parse(name, entry, targets)
      path = [DEPLOY, name]
      if entry.key?("commands")
        raise ChannelChildrenError, "channel '#{path.join(" ")}' declares `commands:`, but a channel has no subcommands — " \
                                    "each destination is its own `deploy` child"
      end

      accepts = accept_patterns(path, entry[ACCEPTS_KEY], targets)
      if entry[RUN_KEY].to_s.empty?
        integration_channel(name, path, entry, accepts)
      else
        if entry.key?(name)
          raise ChannelOptionsError,
            "channel '#{path.join(" ")}' declares `#{name}:` options beside `run:` — the options configure the #{name} " \
              "publisher, which the `run:` replaces; delete one of the two"
        end

        command = T.cast(@command_parser.parse(path, entry), ProjectCommand)
        publisher = Lifecycle::PublisherSpec::Script.new(command: command.run, environment: command.environment)
        Lifecycle::Channel.new(name:, desc: command.desc, accepts:, publisher:)
      end
    end

    private

    # A child with no `run:`: the lock's publisher of the channel's name
    # is its protocol, the child configures what reaches it — its accept
    # set, and the publisher's options under the channel's own name. Read
    # without the CommandParser — a command body needs a `run:` or
    # children, and this child has neither by design — so `desc` is
    # coerced here as the parser coerces it.
    #
    # @param name [String]
    # @param path [Array<String>] the channel's command path, for messages
    # @param entry [DeployHash]
    # @param accepts [Array<Lifecycle::BuildPattern>]
    # @return [Lifecycle::Channel]
    # @raise [ChannelEnvironmentError]
    # @raise [ChannelOptionsError]
    sig do
      params(name: String, path: T::Array[String], entry: DeployHash, accepts: T::Array[Lifecycle::BuildPattern])
        .returns(Lifecycle::Channel)
    end
    def integration_channel(name, path, entry, accepts)
      if entry.key?(CommandParser::ENVIRONMENT_KEY)
        raise ChannelEnvironmentError,
          "channel '#{path.join(" ")}' declares `environment:` without `run:` — an integration's publisher runs where " \
            "dev runs; the key places a `run:` script, so add one or delete the key"
      end

      desc = entry["desc"].to_s
      Lifecycle::Channel.new(
        name:,
        desc: desc.empty? ? Lifecycle::Channel::NO_DESCRIPTION : desc,
        accepts:,
        publisher: Lifecycle::PublisherSpec::Integration.new(name:),
        options: publisher_options(name, path, entry[name]),
      )
    end

    # The publisher's options as declared under the channel's own name: a
    # mapping with string keys, or nothing.
    #
    # @param name [String]
    # @param path [Array<String>] the channel's command path, for messages
    # @param raw [Object] the value under the channel's name, as YAML delivered it
    # @return [Hash{String => Object}]
    # @raise [ChannelOptionsError]
    sig { params(name: String, path: T::Array[String], raw: T.untyped).returns(Lifecycle::Channel::Options) }
    def publisher_options(name, path, raw)
      return {} if raw.nil?
      unless raw.is_a?(Hash)
        raise ChannelOptionsError,
          "channel '#{path.join(" ")}': `#{name}:` must be a mapping of the #{name} publisher's options, got #{raw.inspect}"
      end

      raw.transform_keys(&:to_s)
    end

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
