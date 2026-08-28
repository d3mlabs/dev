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
require_relative "bundler_repository"
require_relative "bundler_integration"
require_relative "xcode_repository"
require_relative "xcode_integration"
require_relative "pip_repository"
require_relative "pip_integration"

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
      # @param repository [Class] Repository subclass that resolves this type
      # @param repository_needs [Array<Symbol>] extra kwargs the repository takes
      # @param integration [Class, nil] Integration subclass that installs this
      #   type, or nil for resolve-only / container-only types
      # @param integration_needs [Array<Symbol>] extra kwargs the integration takes
      #   (beyond the always-passed repository: and cache:)
      # @param scope [Symbol] one of HOST / CONTAINER / BOTH
      Entry = Data.define(
        :symbol, :repository, :repository_needs, :integration, :integration_needs, :scope,
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
            integration: T.nilable(T.class_of(Integration)),
            scope: Symbol,
            repository_needs: T::Array[Symbol],
            integration_needs: T::Array[Symbol],
          ).void
        end
        def initialize(symbol:, repository:, integration:, scope:,
                       repository_needs: [], integration_needs: [])
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
            repository_needs: %i[project_root ruby_version_requirement],
            integration: BundlerIntegration,
            integration_needs: %i[project_root],
            scope: HOST,
          ),
          Entry.new(
            symbol: :brew,
            repository: BrewRepository,
            integration: BrewIntegration,
            integration_needs: %i[taps project_dir],
            scope: BOTH,
          ),
          Entry.new(
            symbol: :cmake,
            repository: GitRepository,
            integration: CmakeIntegration,
            integration_needs: %i[project_root],
            scope: HOST,
          ),
          Entry.new(
            symbol: :luarocks,
            repository: LuaRocksRepository,
            integration: LuaRocksIntegration,
            integration_needs: %i[project_root],
            scope: HOST,
          ),
          Entry.new(
            symbol: :ficsit,
            repository: FicsitRepository,
            integration: FicsitIntegration,
            scope: HOST,
          ),
          Entry.new(
            symbol: :gh,
            repository: GhRepository,
            integration: GhIntegration,
            integration_needs: %i[project_root],
            scope: HOST,
          ),
          Entry.new(
            symbol: :steam,
            repository: SteamRepository,
            integration: SteamIntegration,
            scope: HOST,
          ),
          Entry.new(
            symbol: :xcode,
            repository: XcodeRepository,
            integration: XcodeIntegration,
            integration_needs: %i[project_root],
            scope: HOST,
          ),
          Entry.new(
            symbol: :pip,
            repository: PipRepository,
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
        # @param ruby_version_requirement [String, nil] for the bundler-generated Gemfile
        # @return [Hash{Symbol => Repository}]
        sig do
          params(
            project_root: Pathname,
            ruby_version_requirement: T.nilable(String),
          ).returns(T::Hash[Symbol, Repository])
        end
        def repositories(project_root:, ruby_version_requirement: nil)
          context = { project_root:, ruby_version_requirement: }
          INTEGRATIONS.to_h { |entry| [entry.symbol, build_repository(entry, context)] }
        end

        # Build the integration-type -> Integration hash for host installs.
        #
        # @param project_root [Pathname] project root (threaded to integrations that need it)
        # @param cache [Cache] shared download cache (passed to every integration)
        # @param taps [Array<Tap>] Homebrew taps for the brew integration
        # @param ruby_version_requirement [String, nil] for the bundler repository
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
          T.unsafe(entry.repository).new(**T.unsafe(context).slice(*entry.repository_needs))
        end
      end
    end
  end
end
