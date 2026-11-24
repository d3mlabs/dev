# typed: strict
# frozen_string_literal: true

require_relative "package_version"
require_relative "requirement"
require_relative "series_span"

module Dev
  module Deps
    # Per-integration requirement semantics — a domain service, deliberately
    # separate from the domain objects it evaluates.
    #
    # The layering rule: a Package states facts (which versions exist), a
    # VersionScheme evaluates predicates (does this version satisfy that
    # requirement, and how do this ecosystem's versions order), and the
    # Resolver chooses (take the highest satisfying version). The
    # requirement language is dev's (Requirement); what a version string
    # means and how versions order is a property of an ecosystem, not of
    # any one package's version set, which is why the predicate lives here
    # and not on Package.
    #
    # The contract has three parts. `supports?` says which forms of the
    # language the channel can evaluate at all — a channel with no range to
    # pick over (a cask, a Steam branch tip) refuses a range before any
    # universe is read, with `supported` naming what it does take.
    # `satisfies?` + `sort` evaluate a supported requirement over the
    # universe, for channels dev picks for. `refusal` lets a channel decline
    # a supported form over one particular universe (a brew family with one
    # version has no range to pick among). A channel whose tool solves
    # (bundler) translates instead: GemScheme#render. Every Registry entry
    # must name its scheme, so adding an ecosystem mechanically demands
    # answering "what are its requirement semantics". See
    # docs/deps-architecture.md.
    class VersionScheme
      extend T::Sig

      # Base for every scheme's requirement-reading failure: the requirement
      # parsed in dev's language but names a version this channel cannot
      # read (`>= 1!2` to brew). The user's declaration is wrong, so the
      # Resolver lets it propagate.
      class InvalidRequirementError < StandardError; end

      # Base for every scheme's version-parse failure. A universe can contain
      # versions that predate or ignore the ecosystem's conventions; the
      # Resolver treats such candidates as non-satisfying rather than failing
      # the whole resolve.
      class InvalidVersionError < StandardError; end

      # Can this channel evaluate the requirement's form at all? The static
      # half of the contract: a universe-independent capability table.
      #
      # @param requirement [Requirement]
      # @return [Boolean]
      sig { overridable.params(requirement: Requirement).returns(T::Boolean) }
      def supports?(requirement)
        true
      end

      # What this channel takes, for the refusal a declaration it cannot
      # evaluate gets: the forms and the channel's reason.
      #
      # @return [String]
      sig { overridable.returns(String) }
      def supported
        "any requirement"
      end

      # Does one version satisfy the requirement, under this ecosystem's
      # reading of version strings and comparison rules?
      #
      # Takes the whole PackageVersion, not the bare string: some ecosystems'
      # requirements read a version fact rather than the version string (the
      # git ref a SHA resolved from).
      #
      # @param version [PackageVersion] a candidate version with its facts
      # @param requirement [Requirement] the declaration's requirement
      # @return [Boolean]
      sig { overridable.params(version: PackageVersion, requirement: Requirement).returns(T::Boolean) }
      def satisfies?(version, requirement)
        raise NotImplementedError, "#{self.class}#satisfies? must be implemented"
      end

      # Total order for this ecosystem's versions, ascending.
      #
      # @param versions [Array<PackageVersion>] versions to order
      # @return [Array<PackageVersion>] the same versions, ascending
      sig { overridable.params(versions: T::Array[PackageVersion]).returns(T::Array[PackageVersion]) }
      def sort(versions)
        raise NotImplementedError, "#{self.class}#sort must be implemented"
      end

      # The whole series a requirement covers, when its bounds are series
      # boundaries and nothing finer (`~> 1`, `>= 1, < 2`, `>= 1`): the
      # shape a follower's constraint has, which the Resolver resolves
      # through a series head where the universe keeps one. A requirement
      # with a bound inside a series (`>= 1.4`) names versions, not
      # series, and has no span. A channel whose versions have no major to
      # read answers nil for every requirement.
      #
      # @param requirement [Requirement]
      # @return [SeriesSpan, nil] nil when the requirement is not series-shaped
      sig { overridable.params(requirement: Requirement).returns(T.nilable(SeriesSpan)) }
      def series_span(requirement)
        nil
      end

      # Why a requirement this channel supports in general cannot be
      # evaluated over this universe, if it cannot — the universe-aware
      # half of `supports?`. A brew family with one version has no range to
      # pick among: a range over it is refused, naming the version there is,
      # rather than satisfied today and unanswerable at the next re-lock.
      # The Resolver raises the answer as an UnsupportedRequirementError.
      #
      # @param name [String] the declaration's name
      # @param requirement [Requirement] the declaration's requirement
      # @param versions [Array<PackageVersion>] the universe as reported
      # @return [String, nil] nil when the universe can answer
      sig do
        overridable.params(
          name: String,
          requirement: Requirement,
          versions: T::Array[PackageVersion],
        ).returns(T.nilable(String))
      end
      def refusal(name:, requirement:, versions:)
        nil
      end

      # Why nothing in the universe satisfies the requirement, in the
      # ecosystem's own terms — when the scheme can say more than the
      # Resolver's generic "no version satisfies <requirement>". A range
      # scheme has nothing to add (the requirement and the count say it
      # all); a fact-matching scheme does: which fact moved, and to what.
      # The Resolver uses the answer as the NoSatisfyingVersionError's
      # message, so it names the declaration and the fix.
      #
      # @param name [String] the declaration's name
      # @param requirement [Requirement] the declaration's requirement
      # @param versions [Array<PackageVersion>] the universe as reported
      # @return [String, nil] nil to take the Resolver's generic message
      sig do
        overridable.params(
          name: String,
          requirement: Requirement,
          versions: T::Array[PackageVersion],
        ).returns(T.nilable(String))
      end
      def unsatisfied(name:, requirement:, versions:)
        nil
      end
    end
  end
end
