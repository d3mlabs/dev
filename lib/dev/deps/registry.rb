# frozen_string_literal: true

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

      HOST_SCOPES = [HOST, BOTH].freeze

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
        def initialize(symbol:, repository:, integration:, scope:,
                       repository_needs: [], integration_needs: [])
          super
        end

        # @return [Boolean] whether this type installs on the host
        def host?
          HOST_SCOPES.include?(scope) && !integration.nil?
        end
      end

      INTEGRATIONS = [
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
      ].freeze

      class << self
        # Build the integration-type -> Repository hash the Resolver consumes.
        #
        # @param project_root [Pathname] project root (threaded to repositories that need it)
        # @param ruby_version_requirement [String, nil] for the bundler-generated Gemfile
        # @return [Hash{Symbol => Repository}]
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

            integrations[entry.symbol] = entry.integration.new(
              repository: build_repository(entry, context),
              cache:,
              **context.slice(*entry.integration_needs),
            )
          end
        end

        # @param entry [Entry]
        # @param context [Hash{Symbol => Object}] available constructor arguments
        # @return [Repository]
        def build_repository(entry, context)
          entry.repository.new(**context.slice(*entry.repository_needs))
        end
      end
    end
  end
end
