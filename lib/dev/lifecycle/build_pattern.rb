# typed: strict
# frozen_string_literal: true

require_relative "config"
require_relative "platform"
require_relative "target"
# Build requires this file (Build.parse is the fully-qualified form of the
# grammar here); `dev/lifecycle` loads both.

module Dev
  module Lifecycle
    # The build grammar, `<target>[-<platform>[-<config>]]`, as one parser
    # for every surface that spells a build — the CLI argument,
    # `deploy.<channel>.targets`, `release.targets`, the store's directory
    # names (dev#192, *The model*). Fully qualified it names one build;
    # partially qualified it is a pattern over the target's declared axes,
    # an omitted segment meaning "any". Unambiguous under Target's rule that
    # no target name ends in a platform or config id.
    #
    # Longest declared target prefix first, then an optional platform id,
    # then an optional config id — never a regexp over the whole name.
    class BuildPattern < T::Struct
      extend T::Sig

      # The name starts with no declared target.
      class UnknownTargetError < ArgumentError; end

      # A platform segment the target does not declare (or no platform at
      # all, for a target that declares none).
      class UnsupportedPlatformError < ArgumentError; end

      # A config segment the target does not declare.
      class UnsupportedConfigError < ArgumentError; end

      # Something after the platform and config segments.
      class TrailingSegmentError < ArgumentError; end

      # A single build was asked of a pattern that omits a declared axis.
      class PartialPatternError < ArgumentError; end

      const :target, Target
      const :platform, T.nilable(Platform), default: nil
      const :config, T.nilable(Config), default: nil

      class << self
        extend T::Sig

        # @param name [String] a build name or pattern as written
        # @param targets [Array<Target>] the project's declared targets
        # @return [BuildPattern]
        # @raise [UnknownTargetError]
        # @raise [UnsupportedPlatformError]
        # @raise [UnsupportedConfigError]
        # @raise [TrailingSegmentError]
        sig { params(name: String, targets: T::Array[Target]).returns(BuildPattern) }
        def parse(name, targets)
          target = longest_prefix(name, targets)
          segments = name.delete_prefix(target.name).delete_prefix("-").split("-")
          platform = take_platform(segments, target)
          config = take_config(segments, target)
          unless segments.empty?
            raise TrailingSegmentError,
              "'#{name}': '#{segments.join("-")}' follows the build's segments (#{grammar(target)})"
          end

          new(target:, platform:, config:)
        end

        private

        # @param name [String]
        # @param targets [Array<Target>]
        # @return [Target] the declared target whose name is the longest
        #   prefix of `name` on a segment boundary
        # @raise [UnknownTargetError]
        sig { params(name: String, targets: T::Array[Target]).returns(Target) }
        def longest_prefix(name, targets)
          candidates = targets.select { |target| name == target.name || name.start_with?("#{target.name}-") }
          candidates.max_by { |target| target.name.length } || raise(UnknownTargetError,
            "'#{name}' names no declared target (targets: #{targets.map(&:name).join(", ")})")
        end

        # Consume the platform segment when the next one is a platform id.
        #
        # @param segments [Array<String>] mutated: the id is shifted off
        # @param target [Target]
        # @return [Platform, nil]
        # @raise [UnsupportedPlatformError]
        sig { params(segments: T::Array[String], target: Target).returns(T.nilable(Platform)) }
        def take_platform(segments, target)
          word = segments.first
          return nil unless word && Platform.id?(word)

          platform = Platform.parse(T.must(segments.shift))
          return platform if target.platforms.include?(platform)

          raise UnsupportedPlatformError, "target '#{target}' #{undeclared("platform", platform, target.platforms)}"
        end

        # Consume the config segment when the next one is a config id.
        #
        # @param segments [Array<String>] mutated: the id is shifted off
        # @param target [Target]
        # @return [Config, nil]
        # @raise [UnsupportedConfigError]
        sig { params(segments: T::Array[String], target: Target).returns(T.nilable(Config)) }
        def take_config(segments, target)
          word = segments.first
          return nil unless word && Config.id?(word)

          config = Config.parse(T.must(segments.shift))
          return config if target.configs.include?(config)

          raise UnsupportedConfigError, "target '#{target}' #{undeclared("config", config, target.configs)}"
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

        # @param target [Target]
        # @return [String] the shape of this target's build names
        sig { params(target: Target).returns(String) }
        def grammar(target)
          shape = [target.name]
          shape << "<#{target.platforms.map(&:serialize).join("|")}>" if target.platforms?
          shape << "<#{target.configs.map(&:serialize).join("|")}>" if target.configs?
          "the grammar is #{shape.join("-")}"
        end
      end

      # Whether every axis the target declares is given — the pattern names
      # exactly one build.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def fully_qualified?
        (!target.platforms? || !platform.nil?) && (!target.configs? || !config.nil?)
      end

      # The one build a fully-qualified pattern names.
      #
      # @return [Build]
      # @raise [PartialPatternError]
      sig { returns(Build) }
      def build
        unless fully_qualified?
          spanned = builds
          raise PartialPatternError,
            "'#{name}' omits a declared axis: it is a pattern over #{spanned.size} " \
              "#{spanned.one? ? "build" : "builds"} (#{spanned.map(&:name).join(", ")}) — name one fully"
        end

        Build.new(target:, platform:, config:)
      end

      # Every build of the target the pattern admits, in the target's
      # declaration order.
      #
      # @return [Array<Build>]
      sig { returns(T::Array[Build]) }
      def builds
        target.builds.select { |candidate| matches?(candidate) }
      end

      # The pattern split along the platform axis, the config axis left as
      # written: one pattern per declared platform it admits — itself when
      # it names one already, or when the target declares none. What a
      # channel ships one artifact per (dev#192, K5): a platform is a
      # destination's fact (a Windows box, a Steam depot), a config the
      # operator's choice.
      #
      # @return [Array<BuildPattern>] in the target's platform order
      sig { returns(T::Array[BuildPattern]) }
      def per_platform
        return [self] if platform || !target.platforms?

        target.platforms.map { |declared| BuildPattern.new(target:, platform: declared, config:) }
      end

      # The pattern with each omitted axis filled by the target's default
      # (its first declared value) — what a bare `build <target>` means.
      #
      # @return [Build]
      sig { returns(Build) }
      def default_build
        Build.new(target:, platform: platform || target.platforms.first, config: config || target.configs.first)
      end

      # Whether a build is one of this pattern's.
      #
      # @param candidate [Build]
      # @return [Boolean]
      sig { params(candidate: Build).returns(T::Boolean) }
      def matches?(candidate)
        candidate.target == target && (platform.nil? || candidate.platform == platform) &&
          (config.nil? || candidate.config == config)
      end

      # The pattern as written: the target's name, then the given axes.
      #
      # @return [String]
      sig { returns(String) }
      def name
        [target.name, platform&.serialize, config&.serialize].compact.join("-")
      end

      sig { returns(String) }
      def to_s
        name
      end

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        other.is_a?(BuildPattern) && target == other.target && platform == other.platform && config == other.config
      end

      sig { params(other: Object).returns(T::Boolean) }
      def eql?(other)
        self == other
      end

      sig { returns(Integer) }
      def hash
        [BuildPattern, target, platform, config].hash
      end
    end
  end
end
