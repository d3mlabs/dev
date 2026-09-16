# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "integration"

module Dev
  module Deps
    # Reads locked dependencies and dispatches to integrations.
    #
    # Cross-cutting install concerns (env filtering, build-first ordering)
    # live here — not in Integration or Lockfile.
    class Installer
      extend T::Sig

      # Aggregate of every failure across the whole install run, raised after
      # all integrations were attempted. Entries are ordered by wave (build
      # first), so root causes appear before derivative failures. Raising
      # keeps the caller contract unchanged: a failed run exits non-zero and
      # never writes the installed stamp.
      class InstallFailedError < StandardError
        extend T::Sig

        # @return [Array<String>] one human-readable line per failure
        sig { returns(T::Array[String]) }
        attr_reader :entries

        # @param entries [Array<String>]
        sig { params(entries: T::Array[String]).void }
        def initialize(entries)
          @entries = entries
          super("#{entries.size} dependency install failure(s) — " \
            "installs are idempotent, fix the causes and rerun:\n" \
            "#{entries.map { |entry| "  #{entry}" }.join("\n")}")
        end
      end

      # @param lockfile [Lockfile] lockfile reader
      # @param integrations [Hash{Symbol => Integration}] integration type → integration
      sig { params(lockfile: Lockfile, integrations: T::Hash[Symbol, T.untyped]).void }
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
      # @return [void]
      # @raise [InstallFailedError] if any integration reported failures; every
      #   integration was still attempted (failure isolation)
      sig { params(env: T.nilable(String), host: T.nilable(String)).void }
      def install(env: nil, host: nil)
        all_deps = @lockfile.read
        all_deps = filter_by_env(all_deps, env) if env
        all_deps = filter_by_host(all_deps, host) if host

        build_deps, other_deps = all_deps.partition { |d| d.group == :build }

        failures = dispatch(build_deps) + dispatch(other_deps)
        raise InstallFailedError, failures if failures.any?
      end

      private

      # Dispatch deps to their matching integrations, grouped by integration
      # INSTANCE rather than by type symbol: types that install through a
      # shared instance (Registry install_alias — e.g. :url deps through
      # :cmake's pipeline) must arrive in one install_all call, or an
      # integration generating batch artifacts (deps.cmake) would overwrite
      # its own output with each partial group.
      #
      # A failing integration never blocks the others: the manifest declares
      # no cross-integration edges, so the correct failure policy for the
      # (degenerate) dependency DAG is attempt-all. Failures are collected —
      # per-dep entries when the integration isolated them
      # (PartialInstallError), one entry when it failed whole (e.g. a tap
      # registration preamble) — and reported by the caller's aggregate.
      #
      # @param deps [Array<Dependency>] dependencies to install
      # @return [Array<String>] one entry per failure, in dispatch order
      sig { params(deps: T::Array[Dependency]).returns(T::Array[String]) }
      def dispatch(deps)
        deps.group_by { |dep| @integrations[dep.integration] }.flat_map do |integration, typed_deps|
          next [] unless integration

          label = typed_deps.map(&:integration).uniq.join("+")
          begin
            integration.install_all(typed_deps)
            []
          rescue Integration::PartialInstallError => e
            e.failures.map { |name, error| "#{label}: #{name} — #{error.message}" }
          rescue StandardError => e
            ["#{label}: #{e.message}"]
          end
        end
      end

      # Filter deps by environment. Deps with no env metadata pass through.
      # Deps with env metadata only pass if it matches the given env.
      #
      # @param deps [Array<Dependency>] all deps
      # @param env [String] target environment
      # @return [Array<Dependency>]
      sig { params(deps: T::Array[Dependency], env: String).returns(T::Array[Dependency]) }
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
      sig { params(deps: T::Array[Dependency], host: String).returns(T::Array[Dependency]) }
      def filter_by_host(deps, host)
        deps.select do |dep|
          dep_host = dep.metadata["host"]
          dep_host.nil? || dep_host == host
        end
      end
    end
  end
end
