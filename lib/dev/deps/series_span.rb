# typed: strict
# frozen_string_literal: true

require "dev/lifecycle/series"
require_relative "../value_equality"

module Dev
  module Deps
    # The whole series a **series-shaped** requirement covers: from one
    # series up to, not including, another (`^1`, `>=1 <2`: series 1
    # alone) or every series from one on (`>=1`). The constraint an
    # adopter writes — this major, any minor or patch — read out of a
    # requirement by the channel's scheme (VersionScheme#series_span); a
    # requirement whose bounds fall inside a series (`>=1.4`, `^1.2`)
    # names versions, not series, and has no span.
    #
    # Owns the invariant that a span is not empty: the upper series, when
    # there is one, is above the lower.
    class SeriesSpan
      extend T::Sig
      include Dev::ValueEquality::Derived

      # The upper series is not above the lower: the span covers nothing.
      class EmptySpanError < ArgumentError; end

      # @return [Lifecycle::Series] the first series covered
      sig { returns(Lifecycle::Series) }
      attr_reader :from

      # @return [Lifecycle::Series, nil] the first series not covered; nil when every series from +from+ on is
      sig { returns(T.nilable(Lifecycle::Series)) }
      attr_reader :to

      # @param from [Lifecycle::Series] the first series covered
      # @param to [Lifecycle::Series, nil] the first series past the span, nil for an open span
      # @raise [EmptySpanError]
      sig { params(from: Lifecycle::Series, to: T.nilable(Lifecycle::Series)).void }
      def initialize(from:, to: nil)
        raise EmptySpanError, "a span from #{from} to #{to} covers no series" if to && to.major <= from.major

        @from = from
        @to = to
        freeze
      end

      # Whether a series is wholly inside the span.
      #
      # @param series [Lifecycle::Series]
      # @return [Boolean]
      sig { params(series: Lifecycle::Series).returns(T::Boolean) }
      def covers?(series)
        upper = to
        series.major >= from.major && (upper.nil? || series.major < upper.major)
      end

      # @return [String] `v1`, `v1..v3` (exclusive), `v1..`
      sig { returns(String) }
      def to_s
        upper = to
        return from.to_s if upper && upper.major == from.major + 1

        "#{from}..#{upper}"
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [from, to]
      end
    end
  end
end
