# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "series_head"
require_relative "../value_equality"

module Dev
  module Deps
    # Which rule the Resolver chose a pin's version by, on a universe that
    # keeps series heads — the one place two rules compete: a
    # series-shaped requirement takes the head of the newest series it
    # covers (`Head`), every other requirement takes the greatest
    # satisfying version (`Greatest`). Rides the pin to the lock report,
    # so `dev deps update` says which; it is never written to the lock.
    # A pin from a universe with no heads has no choice to report: the
    # greatest satisfying version is the only rule there.
    #
    # Sealed, so a consumer cases on the variants and T.absurd the rest.
    class Choice
      extend T::Sig
      extend T::Helpers
      abstract!
      sealed!

      # The pin is a series head: what the store's pointer for the newest
      # series the requirement covers names.
      class Head < Choice
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

        # @return [String] `series head v1 → v1.3.0`
        sig { override.returns(String) }
        def to_s
          "series head #{head}"
        end

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [head]
        end
      end

      # The pin is the greatest version satisfying the requirement: the
      # requirement names no whole series, so no head applies.
      class Greatest < Choice
        extend T::Sig
        include Dev::ValueEquality::Derived

        sig { void }
        def initialize
          freeze
        end

        # @return [String]
        sig { override.returns(String) }
        def to_s
          "greatest satisfying"
        end

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          []
        end
      end

      # @return [String] the rule, as the lock report says it
      sig { abstract.returns(String) }
      def to_s; end
    end
  end
end
