# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "cache"
require_relative "tap"
require_relative "brew_repository"
require_relative "brew_integration"
require_relative "git_repository"
require_relative "cmake_integration"
require_relative "luarocks_repository"
require_relative "luarocks_integration"
require_relative "ficsit_repository"
require_relative "ficsit_integration"
require_relative "gh_repository"
require_relative "gh_integration"
require_relative "steam_repository"
require_relative "steam_integration"
require_relative "bundler_locker"
require_relative "bundler_repository"
require_relative "bundler_integration"
require_relative "xcode_repository"
require_relative "xcode_integration"
require_relative "pip_repository"
require_relative "pip_integration"
require_relative "gem_scheme"
require_relative "locker"
require_relative "pep440_scheme"
require_relative "pinned_scheme"
require_relative "rock_scheme"
require_relative "semver_scheme"
require_relative "version_scheme"

module Dev
  module Deps
    # The single source of truth for how each dependency type is wired.
    #
    # Integration wiring used to live in two hand-maintained hashes in the runner
    # — one for resolution (repositories) and one for host install (integrations)
    # — and nothing kept them in sync with the classes that exist. That let a
    # whole integration (LuaRocks) ship resolved-but-never-installed. This table
    # is now the one place a type is declared; the runner derives both hashes from
    # it, and registry_consistency_test.rb fails CI if a repository/integration
    # class or DSL verb is left unwired.
    #
    # Each Entry says which Repository resolves the type, which Integration (if
    # any) installs it, where it installs (scope), and which extra constructor
    # arguments each side needs (drawn from a context the runner assembles).
    module Registry
      # Install location for a type:
      #   :host      installed on the host by `dev install-deps`
      #   :container installed inside the build container (not by install-deps)
      #   :both      installed on the host and, separately, in the container
      HOST = :host
      CONTAINER = :container
      BOTH = :both

      HOST_SCOPES = T.let([HOST, BOTH].freeze, T::Array[Symbol])

      # @param symbol [Symbol] the DSL/declaration integration symbol (e.g. :brew)
      # @param repository [Class] Repository subclass that reports this type's universes
      # @param repository_needs [Array<Symbol>] extra kwargs the repository takes
      # @param scheme [Class] VersionScheme subclass carrying this type's
      #   constraint semantics — every type must answer "how do constraints work"
      # @param locker [Class, nil] Locker subclass for types whose ecosystem tool
      #   owns the whole-set solve (bundler), or nil
      # @param locker_needs [Array<Symbol>] extra kwargs the locker takes
      # @param integration [Class, nil] Integration subclass that installs this
      #   type, or nil for resolve-only / container-only types
      # @param integration_needs [Array<Symbol>] extra kwargs the integration takes
      #   (beyond the always-passed repository: and cache:)
      # @param scope [Symbol] one of HOST / CONTAINER / BOTH
      Entry = Data.define(
        :symbol, :repository, :repository_needs, :scheme, :locker, :locker_needs,
        :integration, :integration_needs, :scope,
      ) do
        extend T::Sig

        # Sorbet's Data.define rewriter can't attach sigs to the generated
        # member readers (sorbet/sorbet#7272), so strict mode needs explicit
        # typed readers. Data#to_h reads members at the C level (it does not
        # call these readers), so the delegation is safe and non-recursive.
        sig { returns(Symbol) }
        def symbol = to_h.fetch(:symbol)

        sig { returns(T.class_of(Repository)) }
        def repository = to_h.fetch(:repository)

        sig { returns(T::Array[Symbol]) }
        def repository_needs = to_h.fetch(:repository_needs)

        sig { returns(T.class_of(VersionScheme)) }
        def scheme = to_h.fetch(:scheme)

        sig { returns(T.nilable(T.class_of(Locker))) }
        def locker = to_h.fetch(:locker)

        sig { returns(T::Array[Symbol]) }
        def locker_needs = to_h.fetch(:locker_needs)

        sig { returns(T.nilable(T.class_of(Integration))) }
        def integration = to_h.fetch(:integration)

        sig { returns(T::Array[Symbol]) }
        def integration_needs = to_h.fetch(:integration_needs)

        sig { returns(Symbol) }
        def scope = to_h.fetch(:scope)

        sig do
          params(
            symbol: Symbol,
            repository: T.class_of(Repository),
            scheme: T.class_of(VersionScheme),
            integration: T.nilable(T.class_of(Integration)),
            scope: Symbol,
            repository_needs: T::Array[Symbol],
            locker: T.nilable(T.class_of(Locker)),
            locker_needs: T::Array[Symbol],
            integration_needs: T::Array[Symbol],
          ).void
        end
        def initialize(symbol:, repository:, scheme:, integration:, scope:,
                       repository_needs: [], locker: nil, locker_needs: [], integration_needs: [])
          super
        end

        # @return [Boolean] whether this type installs on the host
        sig { returns(T::Boolean) }
        def host?
          HOST_SCOPES.include?(scope) && !integration.nil?
        end
      end

      INTEGRATIONS = T.let(
        [
          Entry.new(
            symbol: :bundler,
            repository: BundlerRepository,
            repository_needs: %i[project_root],
            scheme: GemScheme,
            locker: BundlerLocker,
            locker_needs: %i[project_root ruby_version_requirement],
            integration: BundlerIntegration,
            integration_needs: %i[project_root],
            scope: HOST,
          ),
          Entry.new(
            symbol: :brew,
            repository: BrewRepository,
            scheme: PinnedScheme,
            integration: BrewIntegration,
            integration_needs: %i[taps project_dir],
            scope: BOTH,
          ),
          Entry.new(
            symbol: :cmake,
            repository: GitRepository,
            scheme: PinnedScheme,
            integration: CmakeIntegration,
            integration_needs: %i[project_root],
            scope: HOST,
          ),
          Entry.new(
            symbol: :luarocks,
            repository: LuaRocksRepository,
            scheme: RockScheme,
            integration: LuaRocksIntegration,
            integration_needs: %i[project_root],
            scope: HOST,
          ),
          Entry.new(
            symbol: :ficsit,
            repository: FicsitRepository,
            scheme: SemverScheme,
            integration: FicsitIntegration,
            scope: HOST,
          ),
          Entry.new(
            symbol: :gh,
            repository: GhRepository,
            scheme: PinnedScheme,
            integration: GhIntegration,
            integration_needs: %i[project_root],
            scope: HOST,
          ),
          Entry.new(
            symbol: :steam,
            repository: SteamRepository,
            scheme: PinnedScheme,
            integration: SteamIntegration,
            scope: HOST,
          ),
          Entry.new(
            symbol: :xcode,
            repository: XcodeRepository,
            scheme: PinnedScheme,
            integration: XcodeIntegration,
            integration_needs: %i[project_root],
            scope: HOST,
          ),
          Entry.new(
            symbol: :pip,
            repository: PipRepository,
            scheme: Pep440Scheme,
            integration: PipIntegration,
            integration_needs: %i[project_root python_version],
            scope: HOST,
          ),
        ].freeze,
        T::Array[Entry],
      )

      class << self
        extend T::Sig

        # Build the integration-type -> Repository hash the Resolver consumes.
        #
        # @param project_root [Pathname] project root (threaded to repositories that need it)
        # @return [Hash{Symbol => Repository}]
        sig { params(project_root: Pathname).returns(T::Hash[Symbol, Repository]) }
        def repositories(project_root:)
          context = { project_root: }
          INTEGRATIONS.to_h { |entry| [entry.symbol, build_repository(entry, context)] }
        end

        # Build the integration-type -> VersionScheme hash the Resolver consumes.
        # Schemes are stateless domain services, so they take no context.
        #
        # @return [Hash{Symbol => VersionScheme}]
        sig { returns(T::Hash[Symbol, VersionScheme]) }
        def schemes
          INTEGRATIONS.to_h { |entry| [entry.symbol, entry.scheme.new] }
        end

        # Build the integration-type -> Locker hash for types whose ecosystem
        # tool owns the whole-set solve. update-deps runs these before the
        # Resolver so each tool lockfile is materialized when find reads it.
        #
        # @param project_root [Pathname] project root (threaded to lockers that need it)
        # @param ruby_version_requirement [String, nil] for the bundler-generated Gemfile
        # @return [Hash{Symbol => Locker}]
        sig do
          params(
            project_root: Pathname,
            ruby_version_requirement: T.nilable(String),
          ).returns(T::Hash[Symbol, Locker])
        end
        def lockers(project_root:, ruby_version_requirement: nil)
          context = { project_root:, ruby_version_requirement: }
          INTEGRATIONS.each_with_object({}) do |entry, lockers|
            locker = entry.locker
            next unless locker

            # T.unsafe: the keyword set is runtime-selected (locker_needs);
            # the locker constructors' own sigs validate at runtime.
            lockers[entry.symbol] = T.unsafe(locker).new(**T.unsafe(context).slice(*entry.locker_needs))
          end
        end

        # Build the integration-type -> Integration hash for host installs.
        #
        # @param project_root [Pathname] project root (threaded to integrations that need it)
        # @param cache [Cache] shared download cache (passed to every integration)
        # @param taps [Array<Tap>] Homebrew taps for the brew integration
        # @param ruby_version_requirement [String, nil] accepted for caller
        #   convenience; install-time integrations don't need it today
        # @param python_version [String, nil] for the pip integration's venv
        # @return [Hash{Symbol => Integration}]
        sig do
          params(
            project_root: Pathname,
            cache: Cache,
            taps: T::Array[Tap],
            ruby_version_requirement: T.nilable(String),
            python_version: T.nilable(String),
          ).returns(T::Hash[Symbol, Integration])
        end
        def host_integrations(project_root:, cache:, taps: [], ruby_version_requirement: nil, python_version: nil)
          context = {
            project_root:,
            project_dir: project_root,
            ruby_version_requirement:,
            python_version:,
            taps:,
          }
          INTEGRATIONS.each_with_object({}) do |entry, integrations|
            next unless entry.host?

            # T.unsafe: each entry's constructor takes a runtime-selected
            # keyword set (integration_needs), which Sorbet cannot check
            # statically; the constructors' own sigs validate at runtime.
            integrations[entry.symbol] = T.unsafe(T.must(entry.integration)).new(
              repository: build_repository(entry, context),
              cache:,
              **T.unsafe(context).slice(*entry.integration_needs),
            )
          end
        end

        # @param entry [Entry]
        # @param context [Hash{Symbol => Object}] available constructor arguments
        # @return [Repository]
        sig { params(entry: Entry, context: T::Hash[Symbol, T.untyped]).returns(Repository) }
        def build_repository(entry, context)
          # T.unsafe: the keyword set is runtime-selected (repository_needs);
          # the repository constructors' own sigs validate at runtime.
          entry.repository.new(**T.unsafe(context).slice(*entry.repository_needs))
        end
      end
    end
  end
end
