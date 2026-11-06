# typed: strict
# frozen_string_literal: true

require "pathname"
require "yaml"
require "dev/engine_resources"
require "dev/environment_ref"
require "dev/lifecycle"
require_relative "channel_parser"
require_relative "command_parser"
require_relative "project_manifest"
require_relative "release_parser"
require_relative "target_parser"

module Dev
  # The boundary coercion for dev.yml: #load parses it once and rejects the
  # removed keys at parse time — `ruby:`, the Dockerfile path's
  # `build.container` block with every command's `container:` flag
  # (dev#307, dev#311), and every command's `runs_on:` (now `environment:`,
  # dev#409) — each with where it went. dependencies.rb is not read here —
  # the toolchain is a dependency, and only the deps commands evaluate that
  # file.
  #
  # With `targets:` declared (dev#192) it also holds the rules that span
  # targets and commands: `build` and `package` are derived from the
  # targets, so a project may not declare them as commands; no command may
  # be named like a build, so a positional `dev build <build>` is never
  # ambiguous; and `commands: deploy:` is the project's channels — lifted
  # out of the command tree into the manifest's `channels` (ChannelParser),
  # since `deploy` is derived from them; and `commands: release:` is what a
  # release contains — lifted the same way into the manifest's `release`
  # (ReleaseParser), since `release <version>` is derived from it. All are
  # vacuous without targets — the derived verbs do not exist then, and a
  # project's own `build:`, `deploy:` or `release:` is a plain command —
  # except that a `deploy` child shaped like a channel (`targets:`), or a
  # `release` shaped like a declaration (`targets:`), without any target
  # to name is refused with the fix named, rather than silently kept as a
  # command.
  #
  # Stateless: reusable across manifests, inputs arrive as method arguments.
  class ProjectManifestLoader
    extend T::Sig

    # Raised when dev.yml still carries the removed `ruby:` key. The
    # toolchain is a project dependency and is declared only in
    # dependencies.rb. RuntimeError so the CLI boundary reports it as a
    # clean `dev:` error.
    class UnsupportedDevYamlRubyError < RuntimeError; end

    # Raised when dev.yml still carries a retired key: the Dockerfile
    # path's `build.container` block and a command's `container:` flag
    # (the environment is the lock's `image` block, dev#277), or a
    # command's `runs_on:` (the key is `environment:`, dev#409). The
    # message lists each key with its migration. RuntimeError so the CLI
    # boundary reports it as a clean `dev:` error.
    class RetiredKeysError < RuntimeError; end

    # Raised when a project with `targets:` declares `commands: build:` or
    # `commands: package:` — the verbs are derived from the targets
    # (dev#192, K1); what the project wanted to run is a target's builder.
    class DerivedCommandDeclaredError < RuntimeError; end

    # Raised when a project with `targets:` names a command like one of its
    # builds (or a pattern over them): `dev build <build>` is positional,
    # so the two vocabularies may not overlap (dev#192, *The model*).
    class BuildNamedCommandError < RuntimeError; end

    # Raised when a `deploy` child declares `targets:` — the shape of a
    # channel — in a project that declares no `targets:` at the top level:
    # there is no build for it to accept (dev#192, K5).
    class ChannelWithoutTargetsError < RuntimeError; end

    # Raised when `release` declares `targets:` — the shape of a release
    # declaration — in a project that declares no `targets:` at the top
    # level: there is no build for a release to contain (dev#192, K4).
    class ReleaseWithoutTargetsError < RuntimeError; end

    # The verbs `targets:` derives; a project may not declare them.
    DERIVED_COMMANDS = T.let(["build", "package"].freeze, T::Array[String])

    # The key `runs_on:` became (dev#409) — the command parser's key, named
    # here for the migration messages.
    ENVIRONMENT_KEY = CommandParser::ENVIRONMENT_KEY
    # The retired spelling of ENVIRONMENT_KEY.
    RUNS_ON_KEY = "runs_on"

    # What each key of the retired `build.container` block became.
    BLOCK_KEY_MIGRATIONS = T.let(
      {
        "image" => "delete it — the image is the lock's `image` pin",
        "registry" => "delete it — `registry:` on the `image` block, if not the floor's",
        "persist" => "`persist true` in the `image` block",
        "volumes" => "`volume \"…\"` lines in the `image` block",
        "run_env" => "`run_env \"VAR\" => \"ns/key\"` lines in the `image` block",
        "resources" => "`engine:` at the top level of dev.yml",
      }.freeze,
      T::Hash[String, String],
    )
    # The block's keys that fed the Dockerfile build and have no successor.
    GONE_WITH_THE_DOCKERFILE = "delete it — the Dockerfile path is gone (d3mlabs/dev#311)"

    sig do
      params(
        command_parser: CommandParser,
        target_parser: TargetParser,
        channel_parser: ChannelParser,
        release_parser: ReleaseParser,
      ).void
    end
    def initialize(command_parser: CommandParser.new, target_parser: TargetParser.new, channel_parser: ChannelParser.new,
                   release_parser: ReleaseParser.new)
      @command_parser = command_parser
      @target_parser = target_parser
      @channel_parser = channel_parser
      @release_parser = release_parser
    end

    # Parse dev.yml into a manifest.
    #
    # @param dev_yml_path [Pathname]
    # @return [ProjectManifest]
    # @raise [UnsupportedDevYamlRubyError] when dev.yml carries the removed
    #   `ruby:` key
    # @raise [RetiredKeysError] when dev.yml carries `build.container`, a
    #   command's `container:` flag or a command's `runs_on:`
    # @raise [DerivedCommandDeclaredError] when `targets:` is declared
    #   beside `commands: build:` or `commands: package:`
    # @raise [BuildNamedCommandError] when `targets:` is declared and a
    #   command is named like one of its builds
    # @raise [ChannelWithoutTargetsError] when a `deploy` child declares
    #   `targets:` and the project declares none
    # @raise [ReleaseWithoutTargetsError] when `release` declares
    #   `targets:` and the project declares none
    # @raise [ChannelParser::DeployBodyError] and the channel rules, when
    #   `targets:` is declared and `commands: deploy:` is not a tree of channels
    # @raise [ReleaseParser::ReleaseBodyError] and the release rules, when
    #   `targets:` is declared and `commands: release:` is not a declaration
    sig { params(dev_yml_path: Pathname).returns(ProjectManifest) }
    def load(dev_yml_path)
      yaml = YAML.load_file(dev_yml_path)
      reject_removed_ruby_key(yaml)
      reject_retired_keys(yaml)
      warn_retired_runner_key(yaml)
      raw_commands = yaml["commands"] || {}
      targets = @target_parser.parse_all(yaml["targets"])
      channels = parse_channels(raw_commands, targets)
      release = parse_release(raw_commands, targets)
      # Once targets exist, `deploy` is the channels' and `release` the
      # declaration's — neither a command.
      raw_commands = raw_commands.except(ChannelParser::DEPLOY, ReleaseParser::RELEASE) if targets.any?
      commands = T.let(
        raw_commands.to_h { |name, h| [name.to_s, @command_parser.parse([name.to_s], h)] },
        T::Hash[String, ProjectNode],
      )
      reject_derived_commands(commands, targets)
      reject_build_named_commands(commands, targets)
      ProjectManifest.new(
        name: T.cast(yaml["name"], String),
        commands:,
        targets:,
        channels:,
        release:,
        engine: parse_resources(yaml["engine"]),
      )
    end

    # With targets declared, `commands: deploy:` is the project's channels
    # and leaves the command tree (the caller drops the key). Without
    # targets, `deploy` stays a plain command — unless a child already
    # carries `targets:`, the one shape that cannot mean anything there.
    #
    # @param raw_commands [Hash] the `commands` mapping as YAML delivered it
    # @param targets [Hash{String => Lifecycle::Target}]
    # @return [Hash{String => Lifecycle::Channel}] empty without targets
    # @raise [ChannelWithoutTargetsError]
    sig { params(raw_commands: T::Hash[T.untyped, T.untyped], targets: T::Hash[String, Lifecycle::Target]).returns(T::Hash[String, Lifecycle::Channel]) }
    def parse_channels(raw_commands, targets)
      return @channel_parser.parse_all(raw_commands[ChannelParser::DEPLOY], targets.values) if targets.any?
      return {} unless @channel_parser.channels_declared?(raw_commands)

      raise ChannelWithoutTargetsError,
        "dev.yml declares a `deploy` channel (`#{ChannelParser::ACCEPTS_KEY}:` on a `deploy` child) but no `targets:` — " \
          "a channel accepts builds, so declare the targets they come from (d3mlabs/dev#192)"
    end

    # With targets declared, `commands: release:` is what a release contains
    # and leaves the command tree (the caller drops the key); absent, there
    # is no release and no `release` verb. Without targets, `release` stays
    # a plain command — unless it already carries `targets:`, the one shape
    # that cannot mean anything there.
    #
    # @param raw_commands [Hash] the `commands` mapping as YAML delivered it
    # @param targets [Hash{String => Lifecycle::Target}]
    # @return [Lifecycle::ReleaseBuilds, nil] nil without targets or without
    #   a `release` entry
    # @raise [ReleaseWithoutTargetsError]
    sig { params(raw_commands: T::Hash[T.untyped, T.untyped], targets: T::Hash[String, Lifecycle::Target]).returns(T.nilable(Lifecycle::ReleaseBuilds)) }
    def parse_release(raw_commands, targets)
      if targets.any?
        return nil unless raw_commands.key?(ReleaseParser::RELEASE)

        return @release_parser.parse(raw_commands[ReleaseParser::RELEASE], targets.values)
      end
      return nil unless @release_parser.release_declared?(raw_commands)

      raise ReleaseWithoutTargetsError,
        "dev.yml declares what a release contains (`#{ReleaseParser::TARGETS_KEY}:` on `release`) but no `targets:` — " \
          "a release packages builds, so declare the targets they come from (d3mlabs/dev#192)"
    end

    # With targets declared, `build` and `package` exist as derived verbs,
    # so a project command of either name is refused with what to declare
    # instead.
    #
    # @param commands [Hash{String => ProjectNode}] the top-level commands
    # @param targets [Hash{String => Lifecycle::Target}]
    # @return [void]
    # @raise [DerivedCommandDeclaredError]
    sig { params(commands: T::Hash[String, ProjectNode], targets: T::Hash[String, Lifecycle::Target]).void }
    def reject_derived_commands(commands, targets)
      return if targets.empty?

      declared = DERIVED_COMMANDS & commands.keys
      return if declared.empty?

      keys = declared.map { |verb| "`commands: #{verb}:`" }.join(" and ")
      raise DerivedCommandDeclaredError,
        "dev.yml declares #{keys} beside `targets:`, but #{declared.join(" and ")} #{declared.one? ? "is" : "are"} " \
          "derived from `targets:` — declare what it ran as a target's builder and delete the command (d3mlabs/dev#192)"
    end

    # With targets declared, no command at any depth may be named like a
    # build or a build pattern of them: the lifecycle verbs take the build
    # positionally, and a child of the same name would shadow it.
    #
    # @param commands [Hash{String => ProjectNode}] the top-level commands
    # @param targets [Hash{String => Lifecycle::Target}]
    # @return [void]
    # @raise [BuildNamedCommandError]
    sig { params(commands: T::Hash[String, ProjectNode], targets: T::Hash[String, Lifecycle::Target]).void }
    def reject_build_named_commands(commands, targets)
      return if targets.empty?

      build_names = targets.values.flat_map(&:pattern_names)
      offending = command_paths(commands).select { |path| build_names.include?(T.must(path.last)) }
      return if offending.empty?

      raise BuildNamedCommandError,
        "dev.yml names #{offending.one? ? "a command" : "commands"} like a build: " \
          "#{offending.map { |path| "'#{path.join(" ")}'" }.join(", ")} — the lifecycle verbs take a build " \
          "positionally (`dev build <build>`), so rename the command or the target (d3mlabs/dev#192)"
    end

    # Every command path in the tree, parents before children, in
    # declaration order.
    #
    # @param commands [Hash{String => Command}] one level of the tree
    # @param prefix [Array<String>] the path to this level
    # @return [Array<Array<String>>]
    sig { params(commands: T::Hash[String, Command], prefix: T::Array[String]).returns(T::Array[T::Array[String]]) }
    def command_paths(commands, prefix = [])
      commands.flat_map do |name, node|
        path = prefix + [name]
        [path] + command_paths(node.children, path)
      end
    end

    # The retired keys are refused before any command exists: the
    # Dockerfile path's `build.container` block (each key it carries, with
    # where it went) and every command's `container:` flag, and every
    # command's `runs_on:` with its `environment:` replacement — nested
    # commands included, in document order, one message.
    #
    # @param yaml [Hash]
    # @return [void]
    # @raise [RetiredKeysError]
    sig { params(yaml: T::Hash[String, T.untyped]).void }
    def reject_retired_keys(yaml)
      lines = []
      block = yaml.dig("build", "container")
      lines.concat(block_migrations(block)) if block.is_a?(Hash)
      lines.concat(command_key_migrations(["commands"], yaml["commands"]))
      return if lines.empty?

      raise RetiredKeysError,
        "dev.yml carries retired keys — migrate each (the Dockerfile path is gone, d3mlabs/dev#311: " \
          "declare an `image` block in dependencies.rb; `#{RUNS_ON_KEY}:` is `#{ENVIRONMENT_KEY}:`, d3mlabs/dev#409):" \
          "\n  #{lines.join("\n  ")}"
    end

    # @param block [Hash] the `build.container` mapping
    # @return [Array<String>] a line per key the block carries; one for an empty block
    sig { params(block: T::Hash[T.untyped, T.untyped]).returns(T::Array[String]) }
    def block_migrations(block)
      lines = block.keys.map do |key|
        "build.container.#{key} → #{BLOCK_KEY_MIGRATIONS.fetch(key.to_s, GONE_WITH_THE_DOCKERFILE)}"
      end
      lines.empty? ? ["build.container → delete the block"] : lines
    end

    # @param path [Array<String>] the dev.yml path of this `commands:` mapping
    # @param raw [Object] its value as YAML delivered it
    # @return [Array<String>] a migration line per `container:` flag and
    #   per `runs_on:` under it, deepest last
    sig { params(path: T::Array[String], raw: T.untyped).returns(T::Array[String]) }
    def command_key_migrations(path, raw)
      return [] unless raw.is_a?(Hash)

      raw.flat_map do |name, entry|
        next [] unless entry.is_a?(Hash)

        entry_path = path + [name.to_s]
        own = []
        if entry.key?("container")
          value = entry["container"]
          went = if value == false
            "`#{ENVIRONMENT_KEY}: #{EnvironmentRef::HOST}`"
          else
            "delete it (the image's name under `#{ENVIRONMENT_KEY}:`, or nothing)"
          end
          own << "#{(entry_path + ["container"]).join(".")}: #{value.inspect} → #{went}"
        end
        if entry.key?(RUNS_ON_KEY)
          value = entry[RUNS_ON_KEY]
          # The value's domain is unchanged — an `image` block's name, or
          # `host` — so a well-formed value migrates verbatim.
          went = value.is_a?(String) ? "`#{ENVIRONMENT_KEY}: #{value}`" : "`#{ENVIRONMENT_KEY}: <image name> | #{EnvironmentRef::HOST}`"
          own << "#{(entry_path + [RUNS_ON_KEY]).join(".")}: #{value.inspect} → #{went}"
        end
        own + command_key_migrations(entry_path + ["commands"], entry["commands"])
      end
    end

    # `ruby:` is a removed dev.yml key — rejected at parse time with a
    # dependencies.rb migration message instead of silently ignoring it.
    #
    # @param yaml [Hash]
    # @return [void]
    # @raise [UnsupportedDevYamlRubyError]
    sig { params(yaml: T::Hash[String, T.untyped]).void }
    def reject_removed_ruby_key(yaml)
      ruby_version = yaml["ruby"]&.to_s
      return if ruby_version.nil? || ruby_version.empty?

      raise UnsupportedDevYamlRubyError,
        "dev.yml `ruby:` is no longer supported; declare the toolchain in dependencies.rb: " \
          'Dev::Deps.define { ruby "x.y.z" }'
    end

    # `runner:` is a retired dev.yml key — enrollment identity is a machine
    # fact, not a repo declaration: the repo label derives from the repo name
    # and everything else is flags (`dev runner register`). A warning, not an
    # error: the block simply means nothing now, and existing enrollments
    # keep working untouched.
    #
    # @param yaml [Hash]
    # @return [void]
    sig { params(yaml: T::Hash[String, T.untyped]).void }
    def warn_retired_runner_key(yaml)
      return unless yaml.key?("runner")

      $stderr.puts "dev: dev.yml `runner:` is retired and ignored — the repo runner label now derives " \
                   "from the repo name (`dev runner register`); delete the block."
    end

    # The engine floor, the top-level `engine:` block, coerced to integers
    # at the parse boundary; a missing or non-hash block is no hint at all.
    #
    # @param raw [Object, nil] the block as YAML gave it
    # @return [EngineResources::Hint, nil]
    sig { params(raw: T.untyped).returns(T.nilable(EngineResources::Hint)) }
    def parse_resources(raw)
      return nil unless raw.is_a?(Hash)

      cpus = raw["cpus"]
      memory_gib = raw["memory_gib"]
      disk_gib = raw["disk_gib"]
      EngineResources::Hint.new(
        cpus: cpus.nil? ? nil : Integer(cpus),
        memory_gib: memory_gib.nil? ? nil : Integer(memory_gib),
        disk_gib: disk_gib.nil? ? nil : Integer(disk_gib),
      )
    end
  end
end
