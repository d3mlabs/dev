# typed: false
# frozen_string_literal: true

module Dev
  module Deps
    # Fully resolved, immutable reference to a single dependency.
    # Every field is set at fetch time and never changes.
    #
    # - name:         dependency name (e.g. "boost", "luaunit")
    # - integration:  symbol identifying the Integration type (:cmake, :luarocks, :brew, …)
    # - group:        the purpose it was declared for (:app, :test, :build, …) — selection only,
    #                 never install order
    # - version:      exact version string (tag, semver, commit SHA — depends on repo type)
    # - hash:         integrity hash ("SHA256=…") computed during fetch
    # - metadata:     integration-specific extras (url:, repo:, cmake_targets:, tap:, …) plus
    #                 the install-scoping axes (host, env) and provenance (NEEDED_BY)
    # - dependencies: transitive dependencies discovered during fetch ([{name:, constraint:}, …])
    # - post_install: callable or array of callables to run after the dep is fetched.
    #                 Each callable receives (dep, project_root). Not serialized to lockfile.
    # The :hash member (integrity hash) shadows Data#hash; instances are never
    # used as Hash keys, and renaming it would ripple through the lockfile
    # format. Known trade-off.
    Dependency = Data.define(:name, :integration, :group, :version, :hash, :metadata, :dependencies, :post_install) do # rubocop:disable Lint/DataDefineOverride
      def initialize(name:, integration:, group:, version:, hash:, metadata:, dependencies: [], post_install: nil)
        super(name:, integration:, group:, version:, hash:, metadata:, dependencies:, post_install:)
      end
    end

    # Reopened rather than defined in the Data.define block, where a
    # constant would land on the enclosing module (blocks keep the lexical
    # constant scope).
    class Dependency
      # The metadata key naming the integrations whose own manifests need
      # this pin (e.g. ["xcode"] on the xcodes formula): provenance in the
      # lock, written by the Resolver's needs walk and read by the Installer
      # as the edges it orders batches by.
      NEEDED_BY = "needed_by"
    end
  end
end
