# frozen_string_literal: true

require "pathname"
require_relative "lockfile"
require_relative "resolver"
require_relative "dependency_declaration"

module Dev
  module Deps
    # Orchestrates the dependency lifecycle: resolve → lock → install.
    #
    # Cross-cutting concerns (env filtering, install ordering, tap registration)
    # live here — not in Repository, Integration, or Lockfile.
    class DepsOrchestrator
      class TapRegistrationError < StandardError; end

      # Detect the current environment (ci vs dev).
      #
      # CI-like environments (CI=true, Linux) → "ci"; everything else → "dev".
      #
      # @return [String] "ci" or "dev"
      def self.detect_env
        ci_like = ENV["CI"].to_s =~ /\A(true|1)\z/i
        linux = RUBY_PLATFORM.to_s.include?("linux")
        (ci_like || linux) ? "ci" : "dev"
      end

      # @param dir [Pathname] project root directory containing lockfiles
      def initialize(dir:)
        @dir = Pathname(dir)
      end

      # Resolve declarations and write lockfiles.
      #
      # @param declarations [Array<DependencyDeclaration>] declared dependencies
      # @param repositories [Hash{Symbol => Repository}] integration type → repository
      def update_deps(declarations:, repositories:)
        resolver = Resolver.new(repositories:)
        resolved = resolver.resolve(declarations)

        lockfile = Lockfile.new(dir: @dir)
        lockfile.lock(resolved)
      end

      # Read lockfiles and dispatch to integrations.
      #
      # Build-group deps are installed first (tooling), then app + test.
      # When env is set, deps with non-matching env metadata are filtered out.
      # Deps with no env metadata are always included.
      #
      # @param integrations [Hash{Symbol => Integration}] integration type → integration
      # @param env [String, nil] environment name for filtering (auto-detected if nil)
      def install_all(integrations:, env: nil)
        lockfile = Lockfile.new(dir: @dir)
        all_deps = lockfile.read
        all_deps = filter_by_env(all_deps, env) if env

        build_deps, runtime_deps = all_deps.partition { |d| d.group == :build }

        dispatch(build_deps, integrations)
        dispatch(runtime_deps, integrations)
      end

      # Register Homebrew taps declared in a Config.
      #
      # file:// URLs are resolved relative to dir. Sets TAP_NAME and
      # LOCAL_TAP_DIR env vars for the first local tap.
      #
      # @param config [Config] parsed dependency configuration
      # @raise [TapRegistrationError] if `brew tap` fails
      def register_taps(config:)
        taps = config.taps
        return if taps.nil? || taps.empty?

        taps.each_value { |tap| register_single_tap(tap) }
        setup_tap_env(config)
      end

      # Build DependencyDeclaration objects from a Config's groups.
      #
      # Bridges the DSL/Config layer to the Resolver layer. Each runtime entry
      # in each group becomes a DependencyDeclaration.
      #
      # @param config [Config] parsed dependency configuration
      # @return [Array<DependencyDeclaration>]
      def self.declarations_from_config(config)
        declarations = []

        %w[app test build].each do |group_name|
          group = config.group(group_name)
          (group["runtime"] || []).each do |dep_spec|
            dep_spec.each do |name, spec|
              next unless spec.is_a?(Hash)

              integration = (spec["integration"] || "cmake").to_sym
              declarations << DependencyDeclaration.new(
                name:,
                integration:,
                constraint: spec,
                group: group_name.to_sym,
              )
            end
          end
        end

        declarations
      end

      private

      # Dispatch deps to their matching integrations, grouped by type.
      #
      # @param deps [Array<Dependency>] dependencies to install
      # @param integrations [Hash{Symbol => Integration}] available integrations
      def dispatch(deps, integrations)
        deps.group_by(&:integration).each do |type, typed_deps|
          integration = integrations[type]
          integration&.install_all(typed_deps)
        end
      end

      # Filter deps by environment. Deps with no env metadata pass through.
      # Deps with env metadata only pass if it matches the given env.
      #
      # @param deps [Array<Dependency>] all deps
      # @param env [String] target environment
      # @return [Array<Dependency>]
      def filter_by_env(deps, env)
        deps.select do |dep|
          dep_env = dep.metadata["env"]
          dep_env.nil? || dep_env == env
        end
      end

      # Register a single Homebrew tap.
      #
      # @param tap [Hash] tap config with "name" and optional "url"
      # @raise [TapRegistrationError] if `brew tap` fails
      def register_single_tap(tap)
        name = tap["name"]
        url = (tap["url"] || "").to_s.strip

        if url.start_with?("file://")
          path = resolve_file_url(url)
          success = system("brew", "tap", name, path)
          raise TapRegistrationError, "brew tap #{name} #{path} failed" unless success
        else
          success = system("brew", "tap", name)
          raise TapRegistrationError, "brew tap #{name} failed" unless success
        end
      end

      # Resolve a file:// URL to an absolute path relative to @dir.
      #
      # @param url [String] file:// URL
      # @return [String] absolute path
      def resolve_file_url(url)
        path = url.sub(%r{\Afile://}, "")
        path = (@dir / path[2..]).to_s if path.start_with?("./")
        File.expand_path(path)
      end

      # Set TAP_NAME and LOCAL_TAP_DIR for the first local tap.
      #
      # @param config [Config] parsed dependency configuration
      def setup_tap_env(config)
        first_local = config.local_tap_names.first
        return unless first_local

        url = (config.taps[first_local]["url"] || "").to_s.strip
        path = resolve_file_url(url)
        ENV["TAP_NAME"] = first_local
        ENV["LOCAL_TAP_DIR"] = path
      end
    end
  end
end
