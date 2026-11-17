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
    # - source:       the fully qualified reference the integration's service takes to
    #                 return exactly this artifact (a commit SHA, an image digest,
    #                 `name==version`, `tap@commit`) — what Cargo.lock calls `source` and
    #                 package-lock `resolved`. nil when the service offers no such
    #                 reference (a cask, a Steam branch tip); such a pin cannot be kept
    #                 by a re-lock and is re-resolved every time.
    # - metadata:     integration-specific extras (url:, repo:, cmake_targets:, tap:, …) plus
    #                 the install-scoping axes (host, env) and provenance (NEEDED_BY)
    # - dependencies: transitive dependencies discovered during fetch ([{name:, requirement:}, …])
    # - post_install: callable or array of callables to run after the dep is fetched.
    #                 Each callable receives (dep, project_root). Not serialized to lockfile.
    # The :hash member (integrity hash) shadows Data#hash; instances are never
    # used as Hash keys, and renaming it would ripple through the lockfile
    # format. Known trade-off.
    Dependency = Data.define(:name, :integration, :group, :version, :hash, :source, :metadata, :dependencies, :post_install) do # rubocop:disable Lint/DataDefineOverride
      def initialize(name:, integration:, group:, version:, hash:, metadata:, source: nil, dependencies: [], post_install: nil)
        super(name:, integration:, group:, version:, hash:, source:, metadata:, dependencies:, post_install:)
      end

      # Whether every re-lock must re-resolve this pin: it names a version
      # yet no source its service would return exactly that version for, so
      # the lock has nothing to hold it by. A versionless pin (a cask) has
      # nothing to keep and is not unkeepable.
      #
      # @return [Boolean]
      def unkeepable?
        !version.nil? && source.nil?
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
