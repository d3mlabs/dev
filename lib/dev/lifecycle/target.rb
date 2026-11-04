# typed: strict
# frozen_string_literal: true

require_relative "builder_spec"
require_relative "config"
require_relative "packager_spec"
require_relative "platform"
# Build and Target reference each other (a build names its target, a target
# enumerates its builds); build.rb requires this file, and `dev/lifecycle`
# loads both, so neither requires the other here.

module Dev
  module Lifecycle
    # One entry of dev.yml `targets:` — the content axis of what the project
    # can build (a client, the client with Steamworks compiled in, a
    # dedicated server, a library, a gem, an org payload), with the
    # platforms and configs it declares (dev#192, K1). Each declared axis
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

      NAME_PATTERN = /\A[a-z0-9]+(-[a-z0-9]+)*\z/

      const :name, String
      const :desc, String, default: "(no description)"
      # In declaration order: the first is the default `build` picks.
      const :platforms, T::Array[Platform], default: []
      const :configs, T::Array[Config], default: []
      # nil: nothing to compile — `build` is a no-op and `package` runs alone.
      const :builder, T.nilable(BuilderSpec), default: nil
      const :packager, PackagerSpec, factory: -> { PackagerSpec::Archive.new }

      # @param name [String] the `targets:` key
      # @param desc [String]
      # @param platforms [Array<Platform>] the declared subset, first = default
      # @param configs [Array<Config>] the declared subset, first = default
      # @param builder [BuilderSpec, nil] how the install is made; nil for nothing to compile
      # @param packager [PackagerSpec] how the install becomes the archive; dev's `archive` by default
      # @raise [InvalidTargetNameError]
      # @raise [ReservedTargetSuffixError]
      # @raise [DuplicateAxisValueError]
      sig do
        params(
          name: String,
          desc: String,
          platforms: T::Array[Platform],
          configs: T::Array[Config],
          builder: T.nilable(BuilderSpec),
          packager: PackagerSpec,
        ).void
      end
      def initialize(name:, desc: "(no description)", platforms: [], configs: [], builder: nil,
                     packager: PackagerSpec::Archive.new)
        super
        validate_name!
        validate_unique!("platforms", platforms)
        validate_unique!("configs", configs)
      end

      # Whether the target has something to compile (`build:` declared).
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def buildable? = !builder.nil?

      # Whether the target is ever shipped: every packager but `none`. A
      # target that is not is invisible to `package`, `release` and `deploy`.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def packageable? = !packager.is_a?(PackagerSpec::None)

      # Whether builds of this target carry a platform segment.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def platforms? = !platforms.empty?

      # Whether builds of this target carry a config segment.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def configs? = !configs.empty?

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
      def default_build = Build.new(target: self, platform: platforms.first, config: configs.first)

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
      def to_s = name

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        other.is_a?(Target) && name == other.name && desc == other.desc &&
          platforms == other.platforms && configs == other.configs &&
          builder == other.builder && packager == other.packager
      end

      sig { params(other: Object).returns(T::Boolean) }
      def eql?(other) = self == other

      sig { returns(Integer) }
      def hash = [Target, name, desc, platforms, configs, builder, packager].hash

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

        raise DuplicateAxisValueError, "target '#{name}': #{axis} lists #{duplicates.map(&:serialize).join(", ")} more than once"
      end
    end
  end
end
