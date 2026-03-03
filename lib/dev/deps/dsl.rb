# frozen_string_literal: true

module Dev
  module Deps
    # Top-level DSL evaluated inside Dev::Deps.define { ... }.
    class DSL
      attr_reader :taps, :groups, :gems, :ruby_version_requirement

      def initialize
        @taps   = {}
        @groups = {}
        @gems   = []
        @ruby_version_requirement = nil
      end

      def ruby_version(requirement)
        @ruby_version_requirement = requirement.to_s.strip
      end

      def gem(name, version = nil)
        @gems << { "name" => name.to_s, "version" => version.to_s }.reject { |_, v| v.empty? }
      end

      # Declare a Homebrew tap.
      # url: nil uses the Homebrew default (GitHub). "file://..." resolves to a local tap.
      def tap(name, url: nil)
        name_str = name.to_s
        @taps[name_str] = {
          "name" => name_str,
          "url"  => url && url.to_s,
        }
      end

      def group(name, &block)
        group_name = name.to_s
        group_dsl = GroupDSL.new
        group_dsl.instance_eval(&block) if block
        @groups[group_name] = group_dsl.to_h
      end
    end

    # DSL for per-environment entries (inside group :build for env-specific brew).
    class EnvDSL
      def initialize
        @brew = []
        @runtime = []
      end

      def brew(name, **opts)
        name_str = name.to_s
        if opts.empty?
          @brew << name_str
        else
          @brew << { name_str => stringify_keys(opts) }
        end
      end

      def runtime(name, **spec)
        name_str = name.to_s
        return if name_str.empty?
        @runtime << { name_str => stringify_keys(spec) }
      end

      def to_h
        { "brew" => @brew, "runtime" => @runtime }
      end

      private

      def stringify_keys(hash)
        hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
      end
    end

    # DSL for group-scoped deps: runtime (app/test), brew + nested env (build).
    class GroupDSL
      def initialize
        @runtime = []
        @brew    = []
        @envs    = {}
      end

      # Runtime dependency (app or test group).
      # Git: repo:, tag: or commit:.
      # URL: url:, optional hash:.
      # CMake: cmake_targets:, includes:, cmake_target_prefix:.
      def runtime(name, **spec)
        name_str = name.to_s
        return if name_str.empty?
        @runtime << { name_str => stringify_keys(spec) }
      end

      def brew(name, **opts)
        name_str = name.to_s
        return if name_str.empty?
        if opts.empty?
          @brew << name_str
        else
          @brew << { name_str => stringify_keys(opts) }
        end
      end

      def env(name, &block)
        env_name = name.to_s
        env_dsl = EnvDSL.new
        env_dsl.instance_eval(&block) if block
        @envs[env_name] = env_dsl.to_h
      end

      def to_h
        { "runtime" => @runtime, "brew" => @brew, "env" => @envs }
      end

      private

      def stringify_keys(hash)
        hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
      end
    end
  end
end
