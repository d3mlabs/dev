# typed: strict
# frozen_string_literal: true

require_relative "build"
require_relative "build_pattern"
require_relative "target"

module Dev
  module Lifecycle
    # What a release contains (dev#192, K4): the builds `release <version>`
    # packages at the tag and attaches to the GitHub release, as dev.yml's
    # `release:` declares them — `release.targets`, a list in the build
    # grammar, or `release: {}`, every build of every packageable target.
    # In either form a release build is **fully qualified in config**: the
    # archives of a release are one per build, and "cellbound-3d-win64 at
    # 1.2.0" has to mean one file, so a pattern that spans two configs is
    # refused at load with the config to name, and the empty form refuses a
    # packageable target with several configs with the same fix. The
    # platform axis may be left open — a release of `cellbound-3d-release`
    # is one archive per platform, as a channel ships one per platform.
    #
    # Owns the two other invariants of the list: every build is of a
    # packageable target (a `packager: none` target has no archive to
    # attach), and no build appears twice (two assets of one name).
    class ReleaseBuilds
      extend T::Sig

      # A pattern that leaves the config open on a target declaring
      # configs, or — in the empty form — a packageable target that
      # declares several.
      class ConfigNotNamedError < ArgumentError; end

      # A build of a target declaring `packager: none`: nothing to attach.
      class NotPackageableError < ArgumentError; end

      # A build listed twice.
      class DuplicateBuildError < ArgumentError; end

      # `release: {}` in a project with no packageable target.
      class NothingToReleaseError < ArgumentError; end

      # @return [Array<Build>] in declaration order
      sig { returns(T::Array[Build]) }
      attr_reader :builds

      # @param builds [Array<Build>] fully qualified, in declaration order
      # @raise [NotPackageableError]
      # @raise [DuplicateBuildError]
      sig { params(builds: T::Array[Build]).void }
      def initialize(builds:)
        @builds = T.let(builds.freeze, T::Array[Build])
        validate_packageable!
        validate_unique!
        freeze
      end

      class << self
        extend T::Sig

        # The builds `release.targets` names: each pattern with its config
        # given (when the target has one), spelled out per platform.
        #
        # @param patterns [Array<BuildPattern>] the list as parsed, in order
        # @return [ReleaseBuilds]
        # @raise [ConfigNotNamedError]
        # @raise [NotPackageableError]
        # @raise [DuplicateBuildError]
        sig { params(patterns: T::Array[BuildPattern]).returns(ReleaseBuilds) }
        def declared(patterns)
          patterns.each do |pattern|
            next unless pattern.target.configs? && pattern.config.nil?

            raise ConfigNotNamedError,
              "release.targets: '#{pattern}' spans #{pattern.target.configs.map(&:serialize).join(" and ")} — a release " \
                "build names its config (#{pattern.target.configs.map { |config| "#{pattern}-#{config.serialize}" }.join(", ")})"
          end

          new(builds: patterns.flat_map(&:builds))
        end

        # The builds `release: {}` means: every build of every packageable
        # target — each of which must have at most one config, since the
        # empty form names none.
        #
        # @param targets [Array<Target>] the project's declared targets
        # @return [ReleaseBuilds]
        # @raise [NothingToReleaseError]
        # @raise [ConfigNotNamedError]
        sig { params(targets: T::Array[Target]).returns(ReleaseBuilds) }
        def default(targets)
          packageable = targets.select(&:packageable?)
          if packageable.empty?
            raise NothingToReleaseError,
              "`release: {}` releases every packageable target, and no target is packageable " \
                "(every one declares `packager: none`) — declare a target to ship, or delete `release:`"
          end

          several = packageable.select { |target| target.configs.size > 1 }
          unless several.empty?
            raise ConfigNotNamedError,
              "`release: {}` releases every build of every packageable target, but " \
                "#{several.map { |target| "'#{target}'" }.join(", ")} #{several.one? ? "declares" : "declare"} several configs — " \
                "declare `release: { targets: [...] }` naming the config of each release build " \
                "(#{several.flat_map { |target| target.configs.map { |config| "#{target}-#{config.serialize}" } }.join(", ")})"
          end

          new(builds: packageable.flat_map(&:builds))
        end
      end

      # @return [Array<String>] the builds' names, in order
      sig { returns(T::Array[String]) }
      def names
        @builds.map(&:name)
      end

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        other.is_a?(ReleaseBuilds) && @builds == other.builds
      end

      sig { params(other: Object).returns(T::Boolean) }
      def eql?(other)
        self == other
      end

      sig { returns(Integer) }
      def hash
        [ReleaseBuilds, @builds].hash
      end

      private

      # @return [void]
      # @raise [NotPackageableError]
      sig { void }
      def validate_packageable!
        unshipped = @builds.map(&:target).uniq.reject(&:packageable?)
        return if unshipped.empty?

        raise NotPackageableError,
          "release.targets names #{unshipped.map { |target| "'#{target}'" }.join(", ")}, which " \
            "#{unshipped.one? ? "declares" : "declare"} `packager: none` — it is built, never packaged, so a release " \
            "has nothing of it to attach; drop it from the release or give it a packager"
      end

      # @return [void]
      # @raise [DuplicateBuildError]
      sig { void }
      def validate_unique!
        duplicates = @builds.tally.select { |_build, count| count > 1 }.keys
        return if duplicates.empty?

        raise DuplicateBuildError,
          "release.targets names #{duplicates.map { |build| "'#{build}'" }.join(", ")} more than once"
      end
    end
  end
end
