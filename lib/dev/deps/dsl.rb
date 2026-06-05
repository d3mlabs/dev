# frozen_string_literal: true

module Dev
  module Deps
    # Top-level DSL evaluated inside Dev::Deps.define { ... }.
    class DSL
      attr_reader :taps, :groups, :gems, :ruby_version_requirement,
                  :lua_version_value, :registered_integrations, :registered_methods

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

      # Declare the Lua version for LuaRocks integration.
      #
      # @param version [String, Symbol] Lua version (e.g. "5.1")
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
      # The class is mapped to a symbol name used in DSL methods and lockfiles.
      #
      # @param name [Symbol, String] integration identifier (e.g. :wow_curseforge)
      # @param klass [Class, String] Integration subclass or its name
      def register_integration(name, klass)
        @registered_integrations[name.to_sym] = klass
      end

      # Create a named DSL method mapped to a registered integration.
      # The method becomes available inside group blocks via method_missing.
      #
      # @param name [Symbol, String] method name to register (e.g. :wow_curseforge)
      def register_method(name)
        @registered_methods << name.to_sym
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
      class EmptyNameError < StandardError; end

      def initialize
        @brew = []
        @runtime = []
      end

      def brew(name, **opts)
        name_str = name.to_s
        raise EmptyNameError, "brew dependency name cannot be empty" if name_str.empty?

        if opts.empty?
          @brew << name_str
        else
          @brew << { name_str => stringify_keys(opts) }
        end
      end

      def runtime(name, **spec)
        name_str = name.to_s
        raise EmptyNameError, "runtime dependency name cannot be empty" if name_str.empty?

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
      class EmptyNameError < StandardError; end

      def initialize(registered_methods: [])
        @runtime = []
        @brew    = []
        @envs    = {}
        @registered_methods = registered_methods
      end

      # Declare a CMake dependency. Expands github: shorthand if present.
      #
      # @param name [String, Symbol] dependency name
      # @param spec [Hash] options passed through to runtime (tag:, repo:, url:, github:, etc.)
      def cmake(name, **spec)
        spec = expand_github(name, spec)
        spec[:integration] = "cmake"
        runtime(name, **spec)
      end

      # Declare a LuaRocks dependency with an optional version constraint.
      #
      # @param name [String, Symbol] rock name
      # @param constraint [String, nil] version constraint (e.g. ">=3.5")
      # @param spec [Hash] additional options
      def luarocks(name, constraint = nil, **spec)
        spec[:integration] = "luarocks"
        spec[:constraint] = constraint if constraint
        runtime(name, **spec)
      end

      # Declare a dependency using any registered integration by name.
      #
      # @param name [String, Symbol] dependency name
      # @param integration [Symbol, String] integration identifier (e.g. :wow_curseforge)
      # @param spec [Hash] additional options
      def custom(name, integration:, **spec)
        spec[:integration] = integration.to_s
        runtime(name, **spec)
      end

      # Add a runtime dependency. All typed methods (cmake, luarocks, custom)
      # delegate here. Backward compatible entry point.
      #
      # @param name [String, Symbol] dependency name
      # @param spec [Hash] dependency specification
      def runtime(name, **spec)
        name_str = name.to_s
        raise EmptyNameError, "runtime dependency name cannot be empty" if name_str.empty?

        spec = expand_github(name_str, spec) unless spec.key?(:integration)
        @runtime << { name_str => stringify_keys(spec) }
      end

      def brew(name, **opts)
        name_str = name.to_s
        raise EmptyNameError, "brew dependency name cannot be empty" if name_str.empty?

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

      # Dispatch dynamically registered integration methods (e.g. wow_curseforge).
      # Falls back to super for unknown methods.
      #
      # @param method_name [Symbol] called method name
      # @param args [Array] positional arguments (first is the dependency name)
      # @param kwargs [Hash] keyword arguments passed to custom()
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

      # Expand github: shorthand to a full repo: URL.
      #
      # "org/repo" → "https://github.com/org/repo"
      # "org"      → "https://github.com/org/<dep_name>"
      #
      # @param name [String] dependency name (used as repo name for org-only shorthand)
      # @param spec [Hash] spec hash; github: key is consumed and replaced with repo:
      # @return [Hash] spec with github: replaced by repo:
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
