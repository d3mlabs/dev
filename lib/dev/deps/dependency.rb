# frozen_string_literal: true

module Dev
  module Deps
    # Fully resolved, immutable reference to a single dependency.
    # Every field is set at fetch time and never changes.
    #
    # - name:         dependency name (e.g. "boost", "luaunit")
    # - integration:  symbol identifying the Integration type (:cmake, :luarocks, :brew, …)
    # - group:        :app, :test, or :build
    # - version:      exact version string (tag, semver, commit SHA — depends on repo type)
    # - hash:         integrity hash ("SHA256=…") computed during fetch
    # - metadata:     integration-specific extras (url:, repo:, cmake_targets:, tap:, …)
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
  end
end
