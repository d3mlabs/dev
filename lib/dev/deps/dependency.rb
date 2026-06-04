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
    Dependency = Data.define(:name, :integration, :group, :version, :hash, :metadata, :dependencies) do
      def initialize(name:, integration:, group:, version:, hash:, metadata:, dependencies: [])
        super(name:, integration:, group:, version:, hash:, metadata:, dependencies:)
      end
    end
  end
end
