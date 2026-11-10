# typed: strict
# frozen_string_literal: true

require_relative "builder_spec"
require "dev/environment_ref"
require_relative "config"
require_relative "packager_spec"
require_relative "platform"
require_relative "target_environment"
# Build and Target reference each other (a build names its target, a target
# enumerates its builds); build.rb requires this file, and `dev/lifecycle`
# loads both, so neither requires the other here.

module Dev
  module Lifecycle
    # One entry of dev.yml `targets:` — the content axis of what the project
    # can build (a client, the client with Steamworks compiled in, a
    # dedicated server, a library, a gem, an org payload), with the
    # platforms and configs it declares (dev#192, K1) and the environment
    # its builds run in (`environment:`, K8). Each declared axis
    # contributes one segment to the names of the target's builds; a target
    # declaring neither is its own single build.
    #
    # It also declares how its builds are made: a builder (`build:`; none
    # for a target with nothing to compile) and a packager (`package:` or
    # `packager:`; dev's `archive` unless declared, `none` for a target
    # that is built and never shipped).
    #
    # Owns the one rule that keeps the build grammar unambiguous: a target
    # name may not end in a platform or config id, because
    # `<target>-<id>` is how a build of the shorter target spells itself.
    # Owns, too, the fit between its environment and its platforms: a
    # per-platform environment names exactly the platforms declared.
    class Target < T::Struct
      extend T::Sig

      # The name is not a `-`-joined sequence of lower-case alphanumeric
      # segments — the shape a build name, a store directory and an archive
      # file can all carry unchanged.
      class InvalidTargetNameError < ArgumentError; end

      # The name's last segment is a platform or config id — a build of a
      # shorter target would be spelled the same way.
      class ReservedTargetSuffixError < ArgumentError; end

      # A platform or config declared twice on one target.
      class DuplicateAxisValueError < ArgumentError; end

      # A per-platform `environment:` whose platforms are not exactly the
      # target's — one it does not declare, one it declares left out, or
      # any at all on a target with no `platforms:`.
      class EnvironmentPlatformsError < ArgumentError; end

      NAME_PATTERN = /\A[a-z0-9]+(-[a-z0-9]+)*\z/

      const :name, String
      const :desc, String, default: "(no description)"
      # In declaration order: the first is the default `build` picks.
      const :platforms, T::Array[Platform], default: []
      const :configs, T::Array[Config], default: []
      # nil: nothing to compile — `build` is a no-op and `package` runs alone.
      const :builder, T.nilable(BuilderSpec), default: nil
      const :packager, PackagerSpec, factory: -> { PackagerSpec::Archive.new }
      # Where the builds run, as declared; nil leaves it to the project's
      # default, as a command's absent `environment:` does.
      const :environment, T.nilable(TargetEnvironment), default: nil

      # @param name [String] the `targets:` key
      # @param desc [String]
      # @param platforms [Array<Platform>] the declared subset, first = default
      # @param configs [Array<Config>] the declared subset, first = default
      # @param builder [BuilderSpec, nil] how the install is made; nil for nothing to compile
      # @param packager [PackagerSpec] how the install becomes the archive; dev's `archive` by default
      # @param environment [TargetEnvironment, nil] where the builds run; nil = the project's default
      # @raise [InvalidTargetNameError]
      # @raise [ReservedTargetSuffixError]
      # @raise [DuplicateAxisValueError]
      # @raise [EnvironmentPlatformsError]
      sig do
        params(
          name: String,
          desc: String,
          platforms: T::Array[Platform],
          configs: T::Array[Config],
          builder: T.nilable(BuilderSpec),
          packager: PackagerSpec,
          environment: T.nilable(TargetEnvironment),
        ).void
      end
      def initialize(name:, desc: "(no description)", platforms: [], configs: [], builder: nil,
                     packager: PackagerSpec::Archive.new, environment: nil)
        super
        validate_name!
        validate_unique!("platforms", platforms)
        validate_unique!("configs", configs)
        validate_environment_platforms!
      end

      # The environment reference a build on +platform+ runs in: the one
      # declared for every build, the one declared for that platform, or
      # nil when the target leaves it to the project's default.
      #
      # @param platform [Platform, nil] a build's platform; nil for a
      #   platform-less target, whose environment is never per platform
      # @return [EnvironmentRef, nil]
      sig { params(platform: T.nilable(Platform)).returns(T.nilable(EnvironmentRef)) }
      def environment_for(platform)
        declared = environment
        case declared
        when nil then nil
        when TargetEnvironment::Single then declared.reference
        when TargetEnvironment::PerPlatform
          # A platform-less target never carries a per-platform environment
          # (validate_environment_platforms!), and a declared platform is
          # always a key of it.
          declared.references.fetch(T.must(platform))
        else
          # simplecov:disable — the sealed declaration has no third shape;
          # T.absurd keeps the static proof.
          T.absurd(declared)
          # simplecov:enable
        end
      end

      # Whether the target has something to compile (`build:` declared).
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def buildable?
        !builder.nil?
      end

      # Whether the target is ever shipped: every packager but `none`. A
      # target that is not is invisible to `package`, `release` and `deploy`.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def packageable?
        !packager.is_a?(PackagerSpec::None)
      end

      # Whether builds of this target carry a platform segment.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def platforms?
        !platforms.empty?
      end

      # Whether builds of this target carry a config segment.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def configs?
        !configs.empty?
      end

      # Every build of this target: the cross product of its declared axes
      # in declaration order (one build for a target declaring none).
      #
      # @return [Array<Build>]
      sig { returns(T::Array[Build]) }
      def builds
        platform_axis = platforms? ? platforms : [nil]
        config_axis = configs? ? configs : [nil]
        platform_axis.product(config_axis).map { |platform, config| Build.new(target: self, platform:, config:) }
      end

      # What bare `build` makes of this target: its first platform and
      # first config — so a project lists its fast-loop axes first.
      #
      # @return [Build]
      sig { returns(Build) }
      def default_build
        Build.new(target: self, platform: platforms.first, config: configs.first)
      end

      # Every name that, parsed against this target, names a build or a
      # pattern over its builds: the bare name, each axis alone, and the
      # fully-qualified builds. What a command may not be named like.
      #
      # @return [Array<String>]
      sig { returns(T::Array[String]) }
      def pattern_names
        platform_axis = [nil] + platforms
        config_axis = [nil] + configs
        platform_axis.product(config_axis).map { |platform, config| [name, platform&.serialize, config&.serialize].compact.join("-") }
      end

      sig { returns(String) }
      def to_s
        name
      end

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        other.is_a?(Target) && name == other.name && desc == other.desc &&
          platforms == other.platforms && configs == other.configs &&
          builder == other.builder && packager == other.packager && environment == other.environment
      end

      sig { params(other: Object).returns(T::Boolean) }
      def eql?(other)
        self == other
      end

      sig { returns(Integer) }
      def hash
        [Target, name, desc, platforms, configs, builder, packager, environment].hash
      end

      private

      # @return [void]
      # @raise [InvalidTargetNameError]
      # @raise [ReservedTargetSuffixError]
      sig { void }
      def validate_name!
        unless NAME_PATTERN.match?(name)
          raise InvalidTargetNameError,
            "target #{name.inspect}: a target name is lower-case alphanumeric segments joined by single dashes"
        end

        segments = name.split("-")
        last = T.must(segments.last)
        return if segments.one? || !(Platform.id?(last) || Config.id?(last))

        raise ReservedTargetSuffixError,
          "target '#{name}' ends in the platform or config id '#{last}', which would spell a build of " \
            "'#{segments[0...-1]&.join("-")}' — rename the target"
      end

      # @param axis [String] "platforms" or "configs", for the message
      # @param values [Array<Platform>, Array<Config>]
      # @return [void]
      # @raise [DuplicateAxisValueError]
      sig { params(axis: String, values: T::Array[T.any(Platform, Config)]).void }
      def validate_unique!(axis, values)
        duplicates = values.tally.select { |_value, count| count > 1 }.keys
        return if duplicates.empty?

        raise DuplicateAxisValueError, "target '#{name}': #{axis} lists #{ids(duplicates)} more than once"
      end

      # A per-platform environment must name the declared platforms, all of
      # them and no other: a build on an unnamed platform would have no
      # environment, and a named platform the target lacks is a typo or a
      # stale line — dev never guesses which.
      #
      # @return [void]
      # @raise [EnvironmentPlatformsError]
      sig { void }
      def validate_environment_platforms!
        declared = environment
        return unless declared.is_a?(TargetEnvironment::PerPlatform)

        unless platforms?
          raise EnvironmentPlatformsError,
            "target '#{name}' declares no platforms, so `environment:` takes one value, not one per platform " \
              "(got #{declared})"
        end

        undeclared = declared.platforms - platforms
        missing = platforms - declared.platforms
        return if undeclared.empty? && missing.empty?

        faults = []
        faults << "names #{ids(undeclared)}, which the target does not declare" unless undeclared.empty?
        faults << "leaves out #{ids(missing)}" unless missing.empty?
        raise EnvironmentPlatformsError,
          "target '#{name}': the per-platform `environment:` #{faults.join(" and ")} — name exactly its platforms " \
            "(#{ids(platforms)})"
      end

      # @param values [Array<Platform>, Array<Config>]
      # @return [String] the ids, comma-separated
      sig { params(values: T::Array[T.any(Platform, Config)]).returns(String) }
      def ids(values)
        values.map(&:serialize).join(", ")
      end
    end
  end
end
