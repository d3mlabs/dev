# typed: strict
# frozen_string_literal: true

require_relative "scoped_declaration"
require_relative "unlock_set"

module Dev
  module Deps
    # Whole-set solve step for integrations whose ecosystem tool owns
    # dependency resolution.
    #
    # A Locker takes every declaration of its integration type at once and
    # delegates the joint solve to the external tool (bundler's `bundle
    # lock`), materializing the tool's own lockfile. The integration's
    # Repository then reads that lockfile back as a fact universe. This is
    # the home of the batch semantics that used to hide in
    # Repository#prepare: repositories answer per-package questions; lockers
    # solve whole sets. Integrations without a tool-owned solve have no
    # Locker. See docs/deps-architecture.md.
    #
    # A whole-set solve is where a subset re-lock cannot be a filter: the
    # tool is told which of its packages to float (`bundle lock --update
    # <gem>`) and keeps the rest of its own lockfile, so the UnlockSet
    # reaches the Locker rather than the Resolver.
    class Locker
      extend T::Sig

      # Solve the whole declaration set, materializing the tool's lockfile.
      #
      # @param declarations [Array<ScopedDeclaration>] every declaration
      #   of this integration type
      # @param unlock [UnlockSet] which declarations float: none keeps the
      #   tool's lockfile where it still satisfies the declarations, names
      #   float those packages, all floats the whole set
      # @return [void]
      sig { params(declarations: T::Array[ScopedDeclaration], unlock: UnlockSet).void }
      def lock(declarations, unlock: UnlockSet.none)
        raise NotImplementedError, "#{self.class}#lock must be implemented"
      end
    end
  end
end
