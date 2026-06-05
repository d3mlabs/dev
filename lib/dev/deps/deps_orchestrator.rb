# frozen_string_literal: true

require "pathname"
require_relative "lockfile"
require_relative "resolver"

module Dev
  module Deps
    # Orchestrates the dependency lifecycle: resolve → lock → install.
    #
    # Cross-cutting concerns (env filtering, install ordering) live here —
    # not in Repository, Integration, or Lockfile.
    class DepsOrchestrator
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
      # @param repositories [Hash{Symbol => Repository}] integration type → repository
      # @param integrations [Hash{Symbol => Integration}] integration type → integration
      def initialize(dir:, repositories: {}, integrations: {})
        @dir = Pathname(dir)
        @repositories = repositories
        @integrations = integrations
        @resolver = Resolver.new(repositories: @repositories)
        @lockfile = Lockfile.new(dir: @dir)
      end

      # Resolve declarations and write lockfiles.
      #
      # @param declarations [Array<DependencyDeclaration>] declared dependencies
      def resolve_dependencies(declarations)
        resolved = @resolver.resolve(declarations)
        @lockfile.lock(resolved)
      end

      # Read lockfiles and dispatch to integrations.
      #
      # Build-group deps are installed first (tooling), then all others.
      # When env is set, deps with non-matching env metadata are filtered out.
      # Deps with no env metadata are always included.
      #
      # @param env [String, nil] environment name for filtering (nil = no filtering)
      def install_all(env: nil)
        all_deps = @lockfile.read
        all_deps = filter_by_env(all_deps, env) if env

        build_deps, other_deps = all_deps.partition { |d| d.group == :build }

        dispatch(build_deps)
        dispatch(other_deps)
      end

      private

      # Dispatch deps to their matching integrations, grouped by type.
      #
      # @param deps [Array<Dependency>] dependencies to install
      def dispatch(deps)
        deps.group_by(&:integration).each do |type, typed_deps|
          integration = @integrations[type]
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
    end
  end
end
