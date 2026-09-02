# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "dependency"
require_relative "dependency_declaration"
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
      # @param id [PackageId] the package's identity
      # @return [Package] the available versions and their facts
      # @raise [PackageNotFoundError] if the universe has no such package
      sig { params(id: PackageId).returns(Package) }
      def find(id)
        raise NotImplementedError, "#{self.class}#find must be implemented"
      end

      # Fetch a dependency by its unique identifier.
      #
      # DEPRECATED: the per-item pin contract, replaced by #find. It conflates
      # identity, constraint, and choice in one untyped hash; it is deleted
      # together with the Resolver cutover to find/VersionScheme.
      #
      # @param id [Hash<String, Object>] unique resource identifier within this repository
      # @return [Dependency]
      sig { params(id: T::Hash[String, T.untyped]).returns(Dependency) }
      def fetch(id)
        raise NotImplementedError, "#{self.class}#fetch must be implemented"
      end

      # Batch hook called once per integration type before any fetch.
      #
      # DEPRECATED: a lifecycle hook smuggling a whole-set solve through a
      # per-item contract; its bundler use moves to BundlerLocker and the hook
      # is deleted together with the Resolver cutover.
      #
      # @param declarations [Array<DependencyDeclaration>] this type's declarations
      # @return [void]
      sig { params(declarations: T::Array[DependencyDeclaration]).void }
      def prepare(declarations); end
    end
  end
end
