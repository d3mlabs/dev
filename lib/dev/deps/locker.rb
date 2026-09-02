# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "dependency_declaration"

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
    class Locker
      extend T::Sig

      # Solve the whole declaration set, materializing the tool's lockfile.
      #
      # @param declarations [Array<DependencyDeclaration>] every declaration
      #   of this integration type
      # @return [void]
      sig { params(declarations: T::Array[DependencyDeclaration]).void }
      def lock(declarations)
        raise NotImplementedError, "#{self.class}#lock must be implemented"
      end
    end
  end
end
