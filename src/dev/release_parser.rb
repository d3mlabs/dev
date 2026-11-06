# typed: strict
# frozen_string_literal: true

require "dev/lifecycle"

module Dev
  # Parses the dev.yml `commands: release:` entry into the project's
  # Lifecycle::ReleaseBuilds — the dev.yml boundary for the release, as
  # ChannelParser is for channels (dev#192, K4). With targets declared,
  # `release` is derived, not a command: the entry says what a release
  # contains and nothing else — `targets:`, a list in the build grammar
  # parsed against the project's targets (so a name no target spells fails
  # at load), or nothing at all (`release: {}`, `release:`), which means
  # every build of every packageable target. The rules over the list (a
  # config named for every build, packageable targets only, no build
  # twice; the empty form's single-config rule) are ReleaseBuilds' own and
  # surface from its constructors. A `run:` (the verb's body is dev's),
  # `commands:` (the verb has no children) or any other key is refused
  # with the fix named.
  #
  # Stateless: reusable across manifests, inputs arrive as method arguments.
  class ReleaseParser
    extend T::Sig

    # `release` carries a `run:` — but it is derived from `targets:` and
    # has no body of its own.
    class ReleaseBodyError < ArgumentError; end

    # `release` carries `commands:` — the verb has no children.
    class ReleaseChildrenError < ArgumentError; end

    # A key that is neither `targets` nor `desc`.
    class UnknownReleaseKeyError < ArgumentError; end

    # `targets:` present but not a non-empty list of build names.
    class ReleaseTargetsError < ArgumentError; end

    # `release:` holding something other than a mapping or nothing.
    class InvalidReleaseError < ArgumentError; end

    RELEASE = "release"
    TARGETS_KEY = "targets"
    RUN_KEY = "run"
    COMMANDS_KEY = "commands"
    # `desc` is read by nothing — the verb's row is dev's — but a project
    # may keep one beside `targets:` as it does on every entry.
    ALLOWED_KEYS = T.let([TARGETS_KEY, "desc"].freeze, T::Array[String])

    # Whether a raw `commands:` mapping declares a `release` child carrying
    # `targets:` — the shape of a release declaration, which only means
    # something once the project declares targets (the loader refuses it
    # otherwise).
    #
    # @param raw_commands [Object] the `commands` value as YAML delivered it
    # @return [Boolean]
    sig { params(raw_commands: T.untyped).returns(T::Boolean) }
    def release_declared?(raw_commands)
      return false unless raw_commands.is_a?(Hash)

      release = raw_commands[RELEASE]
      return false unless release.is_a?(Hash)

      release.key?(TARGETS_KEY)
    end

    # Parse the `release` entry.
    #
    # @param raw [Object] the `commands: release:` value as YAML delivered
    #   it — nil for `release:` with nothing under it
    # @param targets [Array<Lifecycle::Target>] the project's declared targets
    # @return [Lifecycle::ReleaseBuilds]
    # @raise [InvalidReleaseError]
    # @raise [ReleaseBodyError]
    # @raise [ReleaseChildrenError]
    # @raise [UnknownReleaseKeyError]
    # @raise [ReleaseTargetsError]
    # @raise [Lifecycle::ReleaseBuilds::ConfigNotNamedError] and the list's
    #   other rules
    # @raise [Lifecycle::BuildPattern::UnknownTargetError] and the grammar's
    #   other errors, for a name no target admits
    sig { params(raw: T.untyped, targets: T::Array[Lifecycle::Target]).returns(Lifecycle::ReleaseBuilds) }
    def parse(raw, targets)
      entry = raw.nil? ? {} : raw
      raise InvalidReleaseError, "command '#{RELEASE}': expected a mapping (#{TARGETS_KEY}), got #{raw.inspect}" unless entry.is_a?(Hash)

      reject_body!(entry)
      return Lifecycle::ReleaseBuilds.default(targets) unless entry.key?(TARGETS_KEY)

      Lifecycle::ReleaseBuilds.declared(release_patterns(entry[TARGETS_KEY], targets))
    end

    private

    # @param entry [Hash] the `release` mapping
    # @return [void]
    # @raise [ReleaseBodyError]
    # @raise [ReleaseChildrenError]
    # @raise [UnknownReleaseKeyError]
    sig { params(entry: T::Hash[T.untyped, T.untyped]).void }
    def reject_body!(entry)
      if entry.key?(RUN_KEY)
        raise ReleaseBodyError,
          "command '#{RELEASE}' declares `run:`, but with `targets:` declared #{RELEASE} is dev's cut — tag, package the " \
            "release builds at the tag, attach them to the GitHub release — delete the `run:` and declare what a release " \
            "contains under `#{TARGETS_KEY}:` (or `#{RELEASE}: {}` for every build) (d3mlabs/dev#192)"
      end
      if entry.key?(COMMANDS_KEY)
        raise ReleaseChildrenError, "command '#{RELEASE}' declares `commands:`, but #{RELEASE} has no subcommands — it takes a version"
      end

      unknown = entry.keys.map(&:to_s) - ALLOWED_KEYS
      return if unknown.empty?

      raise UnknownReleaseKeyError,
        "command '#{RELEASE}' declares #{unknown.map { |key| "`#{key}:`" }.join(", ")} — a release declares only " \
          "`#{TARGETS_KEY}:` (the builds it contains); where each build runs is its target's `environment:`"
    end

    # The `targets:` list as patterns in the one grammar.
    #
    # @param raw [Object] the `targets` value as YAML delivered it
    # @param targets [Array<Lifecycle::Target>]
    # @return [Array<Lifecycle::BuildPattern>] in declaration order
    # @raise [ReleaseTargetsError]
    sig { params(raw: T.untyped, targets: T::Array[Lifecycle::Target]).returns(T::Array[Lifecycle::BuildPattern]) }
    def release_patterns(raw, targets)
      unless raw.is_a?(Array) && !raw.empty? && raw.all?(String)
        raise ReleaseTargetsError,
          "command '#{RELEASE}': `#{TARGETS_KEY}:` must be a non-empty list of the builds a release contains " \
            "(`<target>[-<platform>]-<config>`, the config named), got #{raw.inspect} — or `#{RELEASE}: {}` for every build"
      end

      raw.map { |pattern| Lifecycle::BuildPattern.parse(pattern, targets) }
    end
  end
end
