# typed: strict
# frozen_string_literal: true

module Dev
  module Lifecycle
    # A word outside HeadStrategy's set, at a boundary. Beside the enum
    # rather than inside it: a T::Enum body may hold only its own values.
    class UnknownHeadStrategyError < ArgumentError; end

    # How a channel's destination keeps its **head** — what the channel
    # answers when asked for a series and nothing finer. The rule is dev's
    # and the same on every channel: `release` never moves a head, `deploy`
    # moves exactly one. The mechanism is the destination's, and each
    # publisher declares which of the two it has (Publisher#head_strategy):
    #
    # - **Pointed**: the store keeps a movable pointer — a tag, a formula's
    #   stable spec, a branch's live build, a label — and the head is what
    #   it points at. `deploy` moves the pointer; a rollback moves it back,
    #   so the head may name a version lower than the greatest one there.
    # - **Derived**: the store keeps versions and no pointer (rubygems.org,
    #   bare tags), so dev computes the head by one rule, `Head.derive`:
    #   the greatest non-prerelease version there. `deploy` moves the head
    #   by publishing a greater version; nothing else can.
    #
    # The set is closed on purpose: a channel that fits neither (no
    # pointer, and versions not totally ordered) is a third strategy to
    # name here, never a special case in a publisher.
    class HeadStrategy < T::Enum
      extend T::Sig

      enums do
        Pointed = new("pointed")
        Derived = new("derived")
      end

      class << self
        extend T::Sig

        # The strategy a word names — the deserialization every boundary
        # goes through.
        #
        # @param word [String]
        # @return [HeadStrategy]
        # @raise [UnknownHeadStrategyError]
        sig { params(word: String).returns(HeadStrategy) }
        def parse(word)
          try_deserialize(word) ||
            raise(UnknownHeadStrategyError, "unknown head strategy #{word.inspect} (expected #{values.map(&:serialize).join(", ")})")
        end
      end

      # Whether the destination keeps a pointer dev moves, as opposed to
      # versions dev computes over.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def pointed?
        self == Pointed
      end

      # The word, for `dev help deploy` and a report.
      #
      # @return [String]
      sig { returns(String) }
      def to_s
        serialize
      end
    end
  end
end
