# frozen_string_literal: true

module Dev
  module Deps
    # Reads locked dependencies and dispatches to integrations.
    #
    # Cross-cutting install concerns (env filtering, build-first ordering)
    # live here — not in Integration or Lockfile.
    class DependencyInstaller
      # @param lockfile [Lockfile] lockfile reader
      # @param integrations [Hash{Symbol => Integration}] integration type → integration
      def initialize(lockfile:, integrations:)
        @lockfile = lockfile
        @integrations = integrations
      end

      # Read lockfiles and dispatch to integrations.
      #
      # Install order is a simplified topological sort: build-group deps
      # (compilers, build systems) are installed before all others because
      # app/test deps may depend on them at install time (e.g. cmake must
      # exist before a cmake-based library can be built).
      #
      # Today individual integrations (Homebrew, LuaRocks) handle their own
      # internal dependency graphs, so we don't need full topological ordering
      # here. If we later encounter cross-integration transitive dependencies,
      # or integrate a repository that doesn't resolve its own dep graph,
      # this partition would generalize into a proper topological sort.
      #
      # When env/host is set, deps with non-matching env/host metadata are
      # filtered out. Deps without the metadata are always included. Filtering
      # happens here — at install, never at resolve — so the lockfile stays the
      # single source of truth for every environment and host.
      #
      # @param env [String, nil] environment name for filtering (nil = no filtering)
      # @param host [String, nil] host OS name for filtering (nil = no filtering)
      def install(env: nil, host: nil)
        all_deps = @lockfile.read
        all_deps = filter_by_env(all_deps, env) if env
        all_deps = filter_by_host(all_deps, host) if host

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

      # Filter deps by host OS. Deps with no host metadata pass through; deps
      # declared for a host only install on that host (e.g. the Mac editor
      # never downloads on Linux CI, the Linux engine never downloads on Macs).
      #
      # @param deps [Array<Dependency>] all deps
      # @param host [String] detected host OS ("darwin" / "linux")
      # @return [Array<Dependency>]
      def filter_by_host(deps, host)
        deps.select do |dep|
          dep_host = dep.metadata["host"]
          dep_host.nil? || dep_host == host
        end
      end
    end
  end
end
