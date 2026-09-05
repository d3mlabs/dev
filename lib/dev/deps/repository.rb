# typed: strict
# frozen_string_literal: true

require_relative "package"
require_relative "package_id"

module Dev
  module Deps
    # Source adapter over one integration's package universe: given an
    # identity, report the versions the backing service offers and the facts
    # attached to them.
    #
    # Facts only — a Fowler-style repository. A Repository never sees a
    # constraint, never selects a version, and has no lifecycle: it is fully
    # functional from construction, a pure function of (id, datastore).
    # Constraint evaluation belongs to the integration's VersionScheme,
    # selection to the Resolver, and whole-set solves (bundle lock) to the
    # integration's Locker. See docs/deps-architecture.md.
    class Repository
      extend T::Sig

      # The universe has no package under the requested identity.
      class PackageNotFoundError < StandardError; end

      # Report the package under this identity.
      #
      # The filter is the declaration's constraint hash, passed as a
      # server-side locator: ecosystems whose constraint names an identity
      # (a git tag, a release tag, a Steam buildid, a brew formula suffix)
      # need it to locate their — typically singleton — universe, and
      # registry-backed ecosystems may use it to narrow an expensive index.
      # Filtering returns every matching version; it never picks one. A
      # repository must not evaluate range constraints (VersionScheme's job)
      # and must not choose among candidates (the Resolver's job).
      #
      # @param id [PackageId] the package's identity
      # @param filter [Hash] the declaration constraint, as a locator only
      # @return [Package] the available versions and their facts
      # @raise [PackageNotFoundError] if the universe has no such package
      sig { params(id: PackageId, filter: T::Hash[String, T.untyped]).returns(Package) }
      def find(id, filter: {})
        raise NotImplementedError, "#{self.class}#find must be implemented"
      end
    end
  end
end
