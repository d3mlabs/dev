# frozen_string_literal: true

module Dev
  module Deps
    # Top-level DSL evaluated inside Dev::Deps.define { ... }.
    class DSL
      attr_reader :taps, :groups, :gems, :ruby_version_requirement,
                  :lua_version_value, :registered_integrations

      def initialize
        @taps   = {}
        @groups = {}
        @gems   = []
        @ruby_version_requirement = nil
        @lua_version_value = nil
        @registered_integrations = {}
        @registered_methods = []
      end

      def ruby_version(requirement)
        @ruby_version_requirement = requirement.to_s.strip
      end

      def lua_version(version)
        @lua_version_value = version.to_s.strip
      end

      def gem(name, version = nil)
        @gems << { "name" => name.to_s, "version" => version.to_s }.reject { |_, v| v.empty? }
      end

      def tap(name, url: nil)
        name_str = name.to_s
        @taps[name_str] = {
          "name" => name_str,
          "url"  => url && url.to_s,
        }
      end

      # Register a custom Integration class for use in dependencies.rb.
      def register_integration(name, klass)
        @registered_integrations[name.to_sym] = klass
      end

      # Create a named DSL method mapped to a registered integration.
      # The method becomes available inside group blocks.
      def register_method(name)
        @registered_methods << name.to_sym
      end

      def registered_methods
        @registered_methods
      end

      def group(name, &block)
        group_name = name.to_s
        group_dsl = GroupDSL.new(registered_methods: @registered_methods)
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
      def initialize(registered_methods: [])
        @runtime = []
        @brew    = []
        @envs    = {}
        @registered_methods = registered_methods
      end

      # cmake() — sugar for runtime deps with explicit cmake integration tag.
      # Also expands github: shorthand.
      def cmake(name, **spec)
        spec = expand_github(name, spec)
        spec[:integration] = "cmake"
        runtime(name, **spec)
      end

      # luarocks() — sugar for LuaRocks deps.
      def luarocks(name, constraint = nil, **spec)
        spec[:integration] = "luarocks"
        spec[:constraint] = constraint if constraint
        runtime(name, **spec)
      end

      # custom() — generic method for any registered integration.
      def custom(name, integration:, **spec)
        spec[:integration] = integration.to_s
        runtime(name, **spec)
      end

      # runtime() — backward compatible entry point. All dep types flow through here.
      def runtime(name, **spec)
        name_str = name.to_s
        return if name_str.empty?
        spec = expand_github(name_str, spec) unless spec.key?(:integration)
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

      # Handle dynamically registered methods (e.g. wow_curseforge)
      def method_missing(method_name, *args, **kwargs, &block)
        if @registered_methods.include?(method_name.to_sym)
          custom(args.first, integration: method_name, **kwargs)
        else
          super
        end
      end

      def respond_to_missing?(method_name, include_private = false)
        @registered_methods.include?(method_name.to_sym) || super
      end

      private

      # Expand github: shorthand to repo: URL.
      # "org/repo" → "https://github.com/org/repo"
      # "org" → "https://github.com/org/<dep_name>"
      def expand_github(name, spec)
        github = spec.delete(:github)
        return spec unless github

        repo_url = if github.include?("/")
          "https://github.com/#{github}"
        else
          "https://github.com/#{github}/#{name}"
        end
        spec.merge(repo: repo_url)
      end

      def stringify_keys(hash)
        hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
      end
    end
  end
end
