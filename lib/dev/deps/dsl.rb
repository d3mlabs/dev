# frozen_string_literal: true

require_relative "dependency_declaration"

module Dev
  module Deps
    # Top-level DSL evaluated inside Dev::Deps.define { ... }.
    class DSL
      # Group a top-level `gem` declaration lands in when none is given. Bundler's
      # default (unscoped) group, mirroring a hand-written Gemfile's top section.
      DEFAULT_GEM_GROUP = :app

      attr_reader :taps, :groups, :declarations, :ruby_version_requirement,
                  :lua_version_value, :registered_integrations, :registered_methods

      def initialize
        @taps   = {}
        @groups = {}
        @declarations = []
        @ruby_version_requirement = nil
        @lua_version_value = nil
        @registered_integrations = {}
        @registered_methods = []
      end

      # Declare the project's Ruby toolchain — a first-class dependency, on equal
      # footing with brew/cmake/gh. dev provisions this exact version (rbenv +
      # shadowenv) before any command and writes it as the generated Gemfile's
      # `ruby` directive. It is resolved specially (early, pre-dispatch) rather than
      # through the resolver -> lockfile -> install pipeline because it is the
      # interpreter every other dependency and command runs under.
      #
      # @param version [String, Symbol] exact Ruby version (e.g. "4.0.5")
      def ruby(version)
        @ruby_version_requirement = version.to_s.strip
      end

      # Declare the Lua version for LuaRocks integration.
      #
      # @param version [String, Symbol] Lua version (e.g. "5.1")
      def lua_version(version)
        @lua_version_value = version.to_s.strip
      end

      # Declare a Ruby gem. Gems are a first-class dev-managed dependency type
      # backed by bundler: this records a :bundler declaration that rides the
      # normal resolver -> lockfile -> install pipeline (dev generates the
      # Gemfile/Gemfile.lock from these). A top-level gem lands in the default
      # group; use a group block to scope it (e.g. group(:test) { gem ... }).
      #
      # @param name [String, Symbol] gem name
      # @param version [String, nil] version requirement (e.g. "~> 1.17")
      # @param opts [Hash] additional bundler options (e.g. require:, git:)
      def gem(name, version = nil, **opts)
        constraint = opts.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
        constraint["version"] = version.to_s if version
        @declarations << DependencyDeclaration.new(
          name: name.to_s,
          integration: :bundler,
          constraint:,
          group: DEFAULT_GEM_GROUP,
        )
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

      # Declare a dependency group, optionally pinned to a platform and/or host OS.
      #
      # @param name [String, Symbol] group name (e.g. :app, :test, :integration)
      # @param platform [String, nil] platform the group's deps target (e.g. "LinuxServer").
      #   Stamped onto every declaration in the group so the resolver can union platforms
      #   across groups for multi-arch integrations. nil lets each integration pick its default.
      # @param host [Symbol, nil] host OS the group's deps install on (:darwin / :linux).
      #   Sugar that stamps every member declaration, exactly as platform: does; install
      #   filters against the detected host OS (the lockfile stays universal — all hosts'
      #   deps are resolved and locked, filtering happens at install, never at resolve).
      def group(name, platform: nil, host: nil, &block)
        group_name = name.to_s
        group_dsl = GroupDSL.new(group: group_name.to_sym, platform:, host:, registered_methods: @registered_methods)
        group_dsl.instance_eval(&block) if block
        @groups[group_name] = group_dsl.to_h
        @declarations.concat(group_dsl.declarations)
      end
    end

    # DSL for per-environment entries (inside group :build for env-specific brew).
    class EnvDSL
      class EmptyNameError < StandardError; end

      attr_reader :declarations

      # @param group [Symbol] enclosing group, stamped onto declarations
      # @param platform [String, nil] enclosing group's platform
      # @param host [Symbol, nil] enclosing group's host OS
      # @param env [String, nil] environment name ("ci" / "dev"), stamped onto declarations
      def initialize(group: :app, platform: nil, host: nil, env: nil)
        @brew = []
        @declarations = []
        @group = group
        @platform = platform
        @host = host
        @env = env
      end

      def brew(name, **opts)
        name_str = name.to_s
        raise EmptyNameError, "brew dependency name cannot be empty" if name_str.empty?

        if opts.empty?
          @brew << name_str
        else
          @brew << { name_str => stringify_keys(opts) }
        end
        @declarations << DependencyDeclaration.new(
          name: name_str,
          integration: :brew,
          constraint: stringify_keys(opts),
          group: @group,
          platform: @platform,
          host: @host,
          env: @env,
        )
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
      # @param host [Symbol, nil] host OS stamped onto every declaration in this group
      # @param registered_methods [Array<Symbol>] dynamically registered integration methods
      def initialize(group:, platform: nil, host: nil, registered_methods: [])
        @group = group
        @platform = platform
        @host = host
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

      # Declare a Ruby gem scoped to this group (group name -> bundler group).
      #
      # @param name [String, Symbol] gem name
      # @param version [String, nil] version requirement (e.g. "~> 1.17")
      # @param spec [Hash] additional bundler options (e.g. require:, git:)
      def gem(name, version = nil, **spec)
        spec[:version] = version if version
        add_declaration(name, :bundler, spec)
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

      # Declare a GitHub dependency, materialized one of two ways:
      #   - assets:  download prebuilt release asset(s) matching a glob (e.g. the CSS
      #              engine tarball). Prebuilt path.
      #   - build:   fetch the tag's source archive and build it (e.g. stock UE, which
      #              Epic ships as source only). Pass a project-relative script path or
      #              an inline shell string; :none extracts source with no build step
      #              (header-only). dev runs it with $DEV_SOURCE_DIR / $DEV_INSTALL_DIR /
      #              $DEV_VERSION and publishes $DEV_INSTALL_DIR to install_dir/<tag>.
      # Exactly one of assets:/build: must be given (the verb names the FETCH backend;
      # assets/build names how it's MATERIALIZED).
      #
      # The first argument is the declaration name. With github:/repo: it is the name and
      # the slug comes from that option; otherwise it is the "owner/repo" slug and the
      # name is its basename (e.g. gh "EpicGames/UnrealEngine" -> name "UnrealEngine").
      #
      # @param name_or_slug [String, Symbol] dependency name, or "owner/repo" slug
      # @param tag [String] exact tag (e.g. "5.6.1-release") — no floating "latest"
      # @param install_dir [String] host directory the artifact is installed into
      # @param github [String, nil] "owner/repo" slug (shorthand; makes the first arg the name)
      # @param repo [String, nil] alias for github:
      # @param assets [String, nil] glob selecting prebuilt release assets
      # @param build [String, Symbol, nil] build-from-source recipe (script path / shell / :none)
      # @param spec [Hash] additional options
      def gh(name_or_slug, tag:, install_dir:, github: nil, repo: nil, assets: nil, build: nil, **spec)
        slug = (github || repo || name_or_slug).to_s
        name = (github || repo) ? name_or_slug.to_s : slug.split("/").last

        unless [assets, build].compact.size == 1
          raise ArgumentError,
                "gh #{name.inspect}: provide exactly one of assets: (prebuilt release asset) " \
                "or build: (build from source)"
        end

        spec = spec.merge(repo: slug, tag: tag, install_dir: install_dir)
        spec[:assets] = assets if assets
        spec[:build] = build.to_s if build
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

      # Pin the Xcode toolchain — a first-class dep like ruby, but riding the
      # normal resolver -> lockfile -> install pipeline. The integration is
      # inherently darwin-scoped (Xcode only exists on macOS; a no-op on other
      # hosts), so the declaration is safe without explicit host gating. dev
      # installs the pin to /Applications/Xcode-<version>.app via the xcodes
      # CLI (declare `brew "xcodes"` in :build so it
      # exists first) and publishes DEVELOPER_DIR via shadowenv.
      #
      # @param version [String, Symbol] exact Xcode version (e.g. "26.1.1")
      # @param spec [Hash] additional options
      def xcode(version, **spec)
        spec[:version] = version.to_s.strip
        add_declaration("xcode", :xcode, spec)
      end

      # Declare a Homebrew formula/cask.
      #
      # Dual-writes: the existing @brew/groups entry feeds the container build
      # path (bin/install-build-deps.rb), while the additional :brew declaration
      # rides the resolver -> lockfile -> install pipeline so `dev install-deps`
      # installs it on the host too. BrewIntegration skips already-installed
      # formulae, so the host install is idempotent.
      #
      # @param name [String, Symbol] formula or cask name
      # @param opts [Hash] options (tap:, version:, cask:)
      def brew(name, **opts)
        name_str = name.to_s
        raise EmptyNameError, "brew dependency name cannot be empty" if name_str.empty?

        if opts.empty?
          @brew << name_str
        else
          @brew << { name_str => stringify_keys(opts) }
        end
        add_declaration(name_str, :brew, opts.dup)
      end

      # Scope member declarations to an environment ("ci" / "dev"). The env
      # name is a first-class declaration field (like host), landing in the
      # lockfile's env section so install-deps filters it to the matching
      # environment — never smuggled through the constraint hash.
      def env(name, &block)
        env_name = name.to_s
        env_dsl = EnvDSL.new(group: @group, platform: @platform, host: @host, env: env_name)
        env_dsl.instance_eval(&block) if block
        @envs[env_name] = env_dsl.to_h
        @declarations.concat(env_dsl.declarations)
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
      # host: is peeled off the spec into the first-class declaration field —
      # a per-declaration override of the group's host (e.g. `gh ..., host:
      # :darwin` outside a host-gated group). It never reaches the constraint,
      # which describes what the dep is, not where it installs.
      #
      # @param name [String, Symbol] dependency name
      # @param integration [Symbol] integration type
      # @param spec [Hash] constraint spec (symbol keys → stringified)
      def add_declaration(name, integration, spec)
        name_str = name.to_s
        raise EmptyNameError, "dependency name cannot be empty" if name_str.empty?

        post_install = spec.delete(:post_install)
        host = spec.delete(:host) || @host
        spec = expand_github(name_str, spec) if spec.key?(:github)
        constraint = stringify_keys(spec)

        @declarations << DependencyDeclaration.new(
          name: name_str,
          integration:,
          constraint:,
          group: @group,
          platform: @platform,
          host:,
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
