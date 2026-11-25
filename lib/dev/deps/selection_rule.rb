# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "package_version"
require_relative "requirement"
require_relative "series_head"
require_relative "version_scheme"
require_relative "../value_equality"

module Dev
  module Deps
    # The rule by which a requirement is satisfied against a universe. Two
    # rules exist: a series-shaped requirement (`~> 1`, `>= 1, < 2`,
    # `>= 1`) takes the head of the newest series it covers where the
    # universe keeps one (`Head`); every other ask, and every universe
    # without a head the ask covers, takes the greatest satisfying version
    # (`Greatest`). A lock and a `@v1` workflow then read the same head:
    # `~> 1` resolves to what `v1` points at, and a rollback that moves
    # `v1` back reaches the next re-lock too.
    #
    # The rule owns both halves: `for` decides it from the ask and the
    # universe's facts, `pick` applies it to the candidates, and
    # `explanation` accounts for it in the lock report — where there was
    # another rule it could have been. It rides the pin to the report and
    # is never written to the lock: the lock records what was chosen, the
    # report why.
    #
    # Sealed, so a consumer cases on the variants and T.absurd the rest.
    class SelectionRule
      extend T::Sig
      extend T::Helpers
      abstract!
      sealed!

      # The rule for one ask against one universe: the head of the newest
      # covered series, provided that head is among the candidates (a head
      # outside the requirement — a pre-release below the floor — or on a
      # platform the declaration did not ask for is not a candidate, and
      # the head rule does not apply); else the greatest, beside whatever
      # heads the universe kept. On gh the head of the newest covered
      # series is what the latest designation follows when the ask reaches
      # the newest deployed series.
      #
      # @param requirement [Requirement] the declaration's requirement
      # @param scheme [VersionScheme, nil] the integration's semantics; nil
      #   on a channel whose address is the whole ask
      # @param heads [Array<SeriesHead>] the universe's heads, one per series
      #   the store keeps a pointer for
      # @param candidates [Array<String>] the distinct satisfying version strings
      # @return [SelectionRule]
      class << self
        extend T::Sig

        sig do
          params(
            requirement: Requirement,
            scheme: T.nilable(VersionScheme),
            heads: T::Array[SeriesHead],
            candidates: T::Array[String],
          ).returns(SelectionRule)
        end
        def for(requirement:, scheme:, heads:, candidates:)
          span = scheme&.series_span(requirement)
          head = span && heads
            .select { |candidate| span.covers?(candidate.series) && candidates.include?(candidate.version) }
            .max_by { |candidate| candidate.series.major }
          head ? Head.new(head:) : Greatest.new(beside: heads)
        end
      end

      # The pin is a series head: what the store's pointer for the newest
      # series the requirement covers names.
      class Head < SelectionRule
        extend T::Sig
        include Dev::ValueEquality::Derived

        # @return [SeriesHead] the head the pin is
        sig { returns(SeriesHead) }
        attr_reader :head

        # @param head [SeriesHead]
        sig { params(head: SeriesHead).void }
        def initialize(head:)
          @head = head
          freeze
        end

        # @param candidates [Array<PackageVersion>] the satisfying versions, one per version string
        # @param scheme [VersionScheme, nil] unused: the head names its version
        # @return [PackageVersion] the candidate the head names
        sig { override.params(candidates: T::Array[PackageVersion], scheme: T.nilable(VersionScheme)).returns(PackageVersion) }
        def pick(candidates, scheme)
          T.must(candidates.find { |candidate| candidate.version == head.version })
        end

        # @return [String] `series head v1 → v1.3.0`
        sig { override.returns(String) }
        def to_s
          "series head #{head}"
        end

        # @return [String] a head is always worth saying
        sig { override.returns(T.nilable(String)) }
        def explanation
          to_s
        end

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [head]
        end
      end

      # The pin is the greatest version satisfying the requirement: the
      # requirement names no whole series the universe keeps a head for.
      class Greatest < SelectionRule
        extend T::Sig
        include Dev::ValueEquality::Derived

        # @return [Array<SeriesHead>] the heads the universe kept that the
        #   rule passed over; empty on a derived channel
        sig { returns(T::Array[SeriesHead]) }
        attr_reader :beside

        # @param beside [Array<SeriesHead>]
        sig { params(beside: T::Array[SeriesHead]).void }
        def initialize(beside:)
          @beside = T.let(beside.freeze, T::Array[SeriesHead])
          freeze
        end

        # @param candidates [Array<PackageVersion>] the satisfying versions, one per version string
        # @param scheme [VersionScheme, nil] orders them; a scheme-less
        #   universe is taken in the order it was listed
        # @return [PackageVersion] the greatest
        sig { override.params(candidates: T::Array[PackageVersion], scheme: T.nilable(VersionScheme)).returns(PackageVersion) }
        def pick(candidates, scheme)
          T.must((scheme ? scheme.sort(candidates) : candidates).last)
        end

        # @return [String]
        sig { override.returns(String) }
        def to_s
          "greatest satisfying"
        end

        # @return [String, nil] worth saying beside heads the ask did not
        #   take; nil where the greatest was the only rule there was
        sig { override.returns(T.nilable(String)) }
        def explanation
          beside.empty? ? nil : to_s
        end

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [beside]
        end
      end

      # Apply the rule to the candidates.
      #
      # @param candidates [Array<PackageVersion>] the satisfying versions, one per version string
      # @param scheme [VersionScheme, nil] the integration's semantics
      # @return [PackageVersion]
      sig { abstract.params(candidates: T::Array[PackageVersion], scheme: T.nilable(VersionScheme)).returns(PackageVersion) }
      def pick(candidates, scheme); end

      # @return [String] the rule, named
      sig { abstract.returns(String) }
      def to_s; end

      # @return [String, nil] the rule's account of itself for the lock
      #   report; nil when no other rule could have applied
      sig { abstract.returns(T.nilable(String)) }
      def explanation; end
    end
  end
end
