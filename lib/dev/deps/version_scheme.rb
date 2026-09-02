# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module Dev
  module Deps
    # Per-integration constraint semantics — a domain service, deliberately
    # separate from the domain objects it evaluates.
    #
    # The layering rule: a Package states facts (which versions exist), a
    # VersionScheme evaluates predicates (does this version satisfy that
    # constraint, and how do this ecosystem's versions order), and the Resolver
    # chooses (take the highest satisfying version). Constraint syntax is a
    # property of an ecosystem, not of any one package's version set, which is
    # why the predicate lives here and not on Package.
    #
    # This is also the seam for a future dev-native constraint syntax: the DSL
    # boundary would parse dev syntax into a typed constraint value, and each
    # scheme would translate it into its ecosystem's query — the satisfies?/sort
    # signatures do not move. Every Registry entry must name its scheme, so
    # adding an ecosystem mechanically demands answering "what are its
    # constraint semantics". See docs/deps-architecture.md.
    class VersionScheme
      extend T::Sig

      # Base for every scheme's constraint-parse failure. A bad constraint is
      # the user's declaration being wrong, so the Resolver lets it propagate.
      class InvalidConstraintError < StandardError; end

      # Base for every scheme's version-parse failure. A universe can contain
      # versions that predate or ignore the ecosystem's conventions; the
      # Resolver treats such candidates as non-satisfying rather than failing
      # the whole resolve.
      class InvalidVersionError < StandardError; end

      # Does one version satisfy the constraint, under this ecosystem's syntax
      # and comparison rules?
      #
      # @param version [String] a version string in this ecosystem's vocabulary
      # @param constraint [Hash] the declaration's constraint hash
      # @return [Boolean]
      sig { params(version: String, constraint: T::Hash[String, T.untyped]).returns(T::Boolean) }
      def satisfies?(version, constraint)
        raise NotImplementedError, "#{self.class}#satisfies? must be implemented"
      end

      # Total order for this ecosystem's version strings, ascending.
      #
      # @param versions [Array<String>] version strings to order
      # @return [Array<String>] the same versions, ascending
      sig { params(versions: T::Array[String]).returns(T::Array[String]) }
      def sort(versions)
        raise NotImplementedError, "#{self.class}#sort must be implemented"
      end
    end
  end
end
