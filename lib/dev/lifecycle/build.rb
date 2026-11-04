# typed: strict
# frozen_string_literal: true

require_relative "build_pattern"
require_relative "config"
require_relative "platform"
require_relative "target"

module Dev
  module Lifecycle
    # One build: a target × one of its platforms × one of its configs — what
    # `build` produces and the fully-qualified name every verb, the store
    # and the archive carry (dev#192, *The model*). An axis the target does
    # not declare is absent and contributes no segment, so a target with
    # neither is its own single build and its name is the build name.
    #
    # Owns the invariant that each axis is present exactly when the target
    # declares it, and holds one of the target's declared values.
    class Build < T::Struct
      extend T::Sig

      # The platform is absent for a target that declares platforms, present
      # for one that does not, or outside the target's declared subset.
      class PlatformMismatchError < ArgumentError; end

      # The config is absent for a target that declares configs, present for
      # one that does not, or outside the target's declared subset.
      class ConfigMismatchError < ArgumentError; end

      const :target, Target
      const :platform, T.nilable(Platform), default: nil
      const :config, T.nilable(Config), default: nil

      # @param target [Target]
      # @param platform [Platform, nil] one of the target's, iff it declares any
      # @param config [Config, nil] one of the target's, iff it declares any
      # @raise [PlatformMismatchError]
      # @raise [ConfigMismatchError]
      sig { params(target: Target, platform: T.nilable(Platform), config: T.nilable(Config)).void }
      def initialize(target:, platform: nil, config: nil)
        super
        validate_platform!
        validate_config!
      end

      class << self
        extend T::Sig

        # The build a fully-qualified name spells, by the one grammar
        # (BuildPattern.parse): `<target>[-<platform>[-<config>]]`, each
        # segment present exactly when the target declares that axis. What
        # the store's directory names and a manifest's `build` go through.
        #
        # @param name [String]
        # @param targets [Array<Target>] the project's declared targets
        # @return [Build]
        # @raise [BuildPattern::UnknownTargetError]
        # @raise [BuildPattern::UnsupportedPlatformError]
        # @raise [BuildPattern::UnsupportedConfigError]
        # @raise [BuildPattern::TrailingSegmentError]
        # @raise [BuildPattern::PartialPatternError] when a declared axis is omitted
        sig { params(name: String, targets: T::Array[Target]).returns(Build) }
        def parse(name, targets)
          BuildPattern.parse(name, targets).build
        end
      end

      # The fully-qualified name: the target's, then the declared axes'.
      #
      # @return [String]
      sig { returns(String) }
      def name = [target.name, platform&.serialize, config&.serialize].compact.join("-")

      sig { returns(String) }
      def to_s = name

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        other.is_a?(Build) && target == other.target && platform == other.platform && config == other.config
      end

      sig { params(other: Object).returns(T::Boolean) }
      def eql?(other) = self == other

      sig { returns(Integer) }
      def hash = [Build, target, platform, config].hash

      private

      # @return [void]
      # @raise [PlatformMismatchError]
      sig { void }
      def validate_platform!
        given = platform
        if given.nil?
          return unless target.platforms?

          raise PlatformMismatchError,
            "target '#{target}' declares platforms (#{target.platforms.map(&:serialize).join(", ")}); a build of it names one"
        end
        return if target.platforms.include?(given)

        raise PlatformMismatchError, "target '#{target}' #{undeclared("platform", given, target.platforms)}"
      end

      # @return [void]
      # @raise [ConfigMismatchError]
      sig { void }
      def validate_config!
        given = config
        if given.nil?
          return unless target.configs?

          raise ConfigMismatchError,
            "target '#{target}' declares configs (#{target.configs.map(&:serialize).join(", ")}); a build of it names one"
        end
        return if target.configs.include?(given)

        raise ConfigMismatchError, "target '#{target}' #{undeclared("config", given, target.configs)}"
      end

      # @param axis [String] "platform" or "config"
      # @param value [Platform, Config] what was asked for
      # @param declared [Array<Platform>, Array<Config>] what the target has
      # @return [String] the clause after "target 'x' "
      sig { params(axis: String, value: T.any(Platform, Config), declared: T::Array[T.any(Platform, Config)]).returns(String) }
      def undeclared(axis, value, declared)
        return "declares no #{axis}s; its builds carry no #{axis} segment" if declared.empty?

        "does not declare #{axis} '#{value}' (declared: #{declared.map(&:serialize).join(", ")})"
      end
    end
  end
end
