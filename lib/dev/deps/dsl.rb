# frozen_string_literal: true

require_relative "dependency_declaration"

module Dev
  module Deps
    # Top-level DSL evaluated inside Dev::Deps.define { ... }.
    class DSL
      attr_reader :taps, :groups, :declarations, :gems, :ruby_version_requirement,
                  :lua_version_value, :registered_integrations, :registered_methods

      def initialize
        @taps   = {}
        @groups = {}
        @declarations = []
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

      # Register a custom integration: maps the name to an Integration class
      # and creates a DSL method so it can be used inside group blocks.
      #
      # @param name [Symbol, String] integration identifier (e.g. :wow_curseforge)
      # @param klass [Class, String] Integration subclass or its name
      def register(name, klass)
        sym = name.to_sym
        @registered_integrations[sym] = klass
        @registered_methods << sym
      end

      # Declare a dependency group, optionally pinned to a platform.
      #
      # @param name [String, Symbol] group name (e.g. :app, :test, :integration)
      # @param platform [String, nil] platform the group's deps target (e.g. "LinuxServer").
      #   Stamped onto every declaration in the group so the resolver can union platforms
      #   across groups for multi-arch integrations. nil lets each integration pick its default.
      def group(name, platform: nil, &block)
        group_name = name.to_s
        group_dsl = GroupDSL.new(group: group_name.to_sym, platform:, registered_methods: @registered_methods)
        group_dsl.instance_eval(&block) if block
        @groups[group_name] = group_dsl.to_h
        @declarations.concat(group_dsl.declarations)
      end
    end

    # DSL for per-environment entries (inside group :build for env-specific brew).
    class EnvDSL
      class EmptyNameError < StandardError; end

      def initialize
        @brew = []
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

      def to_h
        { "brew" => @brew }
      end

      private

      def stringify_keys(hash)
        hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
      end
    end

    # DSL for group-scoped deps: declarations (app/test), brew + nested env (build).
    class GroupDSL
      class EmptyNameError < StandardError; end

      attr_reader :declarations

      # @param group [Symbol] group name (e.g. :app, :test, :build)
      # @param platform [String, nil] platform stamped onto every declaration in this group
      # @param registered_methods [Array<Symbol>] dynamically registered integration methods
      def initialize(group:, platform: nil, registered_methods: [])
        @group = group
        @platform = platform
        @declarations = []
        @brew    = []
        @envs    = {}
        @registered_methods = registered_methods
      end

      # Declare a CMake dependency. Expands github: shorthand if present.
      #
      # @param name [String, Symbol] dependency name
      # @param spec [Hash] options (tag:, repo:, url:, github:, etc.)
      def cmake(name, **spec)
        spec = expand_github(name, spec)
        add_declaration(name, :cmake, spec)
      end

      # Declare a LuaRocks dependency with an optional version constraint.
      #
      # @param name [String, Symbol] rock name
      # @param constraint [String, nil] version constraint (e.g. ">=3.5")
      # @param spec [Hash] additional options
      def luarocks(name, constraint = nil, **spec)
        spec[:constraint] = constraint if constraint
        add_declaration(name, :luarocks, spec)
      end

      # Declare a Satisfactory mod dependency from ficsit.app.
      #
      # @param mod_reference [String, Symbol] mod reference (e.g. "SML", "AreaActions")
      # @param version [String, nil] semver constraint (e.g. "^3.12.0", ">=1.0")
      # @param spec [Hash] additional options (target:, etc.)
      def ficsit(mod_reference, version: nil, **spec)
        spec[:version] = version if version
        add_declaration(mod_reference, :ficsit, spec)
      end

      # Declare a GitHub release artifact dependency (e.g. the custom UE engine).
      #
      # The declaration name is the repo basename; the full slug is kept in
      # the constraint so the resolver can query the GitHub API.
      #
      # @param slug [String, Symbol] GitHub "owner/repo" slug
      # @param tag [String] exact release tag (e.g. "5.6.1-css-83") — no floating "latest"
      # @param assets [String] glob pattern selecting release assets
      # @param install_dir [String] host directory the artifact is installed into
      # @param spec [Hash] additional options
      def gh(slug, tag:, assets:, install_dir:, **spec)
        slug_str = slug.to_s
        name = slug_str.split("/").last
        spec = spec.merge(repo: slug_str, tag: tag, assets: assets, install_dir: install_dir)
        add_declaration(name, :gh, spec)
      end

      # Declare a Steam application dependency (e.g. the Satisfactory Dedicated
      # Server), provisioned via SteamCMD into a host install_dir.
      #
      # The depot platform comes from the consuming group's platform:, so this
      # method takes no platform of its own. Pass buildid: to pin an exact build;
      # otherwise the resolver floats to the current public-branch build.
      #
      # @param name [String, Symbol] dependency name (e.g. "SatisfactoryServer")
      # @param app [Integer, String] Steam app id (e.g. 1690800)
      # @param install_dir [String] host directory the depot is installed into
      # @param branch [String] Steam branch (default "public")
      # @param spec [Hash] additional options (buildid:, etc.)
      def steam(name, app:, install_dir:, branch: "public", **spec)
        spec = spec.merge(app:, install_dir:, branch:)
        add_declaration(name, :steam, spec)
      end

      # Declare a dependency using any registered integration by name.
      #
      # @param name [String, Symbol] dependency name
      # @param integration [Symbol, String] integration identifier (e.g. :wow_curseforge)
      # @param spec [Hash] additional options
      def custom(name, integration:, **spec)
        add_declaration(name, integration.to_sym, spec)
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
        { "brew" => @brew, "env" => @envs, "platform" => @platform }
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

      # Create a DependencyDeclaration and store it.
      #
      # @param name [String, Symbol] dependency name
      # @param integration [Symbol] integration type
      # @param spec [Hash] constraint spec (symbol keys → stringified)
      def add_declaration(name, integration, spec)
        name_str = name.to_s
        raise EmptyNameError, "dependency name cannot be empty" if name_str.empty?

        post_install = spec.delete(:post_install)
        spec = expand_github(name_str, spec) if spec.key?(:github)
        constraint = stringify_keys(spec)

        @declarations << DependencyDeclaration.new(
          name: name_str,
          integration:,
          constraint:,
          group: @group,
          platform: @platform,
          post_install:,
        )
      end

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
