# typed: strict
# frozen_string_literal: true

require_relative "package_version"

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
      # Takes the whole PackageVersion, not the bare string: some ecosystems'
      # constraints match version facts rather than the version string (a
      # Steam branch, the git ref a SHA resolved from, a brew formula suffix).
      # Range schemes read only version.version.
      #
      # @param version [PackageVersion] a candidate version with its facts
      # @param constraint [Hash] the declaration's constraint hash
      # @return [Boolean]
      sig { params(version: PackageVersion, constraint: T::Hash[String, T.untyped]).returns(T::Boolean) }
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

      # The exact version coordinate this constraint pins, if any — the
      # Resolver passes it to Repository#find as the probe, the access path
      # for universes that cannot enumerate (a git commit, a brew @suffix
      # formula). nil for range constraints and for enumerable ecosystems,
      # whose schemes never override this. Extraction lives on the scheme
      # because the constraint keys are the scheme's vocabulary; the raw
      # constraint hash itself never reaches a Repository.
      #
      # @param constraint [Hash] the declaration's constraint hash
      # @return [String, nil] the pinned coordinate, or nil
      sig { params(constraint: T::Hash[String, T.untyped]).returns(T.nilable(String)) }
      def pin(constraint)
        nil
      end
    end
  end
end
