# typed: strict
# frozen_string_literal: true

require "dev/lifecycle/series"
require_relative "../value_equality"

module Dev
  module Deps
    # One series' head as a fact of a package's universe: the version the
    # store's pointer for that series names, in the store's own spelling
    # (the tag `v1` of a gh repo points at the commit `v1.3.0` was cut at,
    # so the head of series `v1` is the version `v1.3.0`). A universe
    # reports one per series the store keeps a pointer for; a store with
    # no pointers (a derived channel) reports none.
    #
    # A fact, unconditional: which version a pointer names does not depend
    # on who asked. Whether a declaration takes the head or the greatest
    # satisfying version is the Resolver's rule.
    class SeriesHead
      extend T::Sig
      include Dev::ValueEquality::Derived

      # @return [Lifecycle::Series] the series the pointer is kept for
      sig { returns(Lifecycle::Series) }
      attr_reader :series

      # @return [String] the version the pointer names, as the universe spells it
      sig { returns(String) }
      attr_reader :version

      # @param series [Lifecycle::Series]
      # @param version [String] a version of the same universe
      sig { params(series: Lifecycle::Series, version: String).void }
      def initialize(series:, version:)
        @series = series
        @version = version
        freeze
      end

      # @return [String] `v1 → v1.3.0`
      sig { returns(String) }
      def to_s
        "#{series} → #{version}"
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [series, version]
      end
    end
  end
end
