# typed: strict
# frozen_string_literal: true

module Dev
  module Lifecycle
    # What a publisher says of the upload it made (dev#192, K5, K6): the
    # one output dev takes from the black box — the destination's own
    # handle on what landed (a Steam build id, the formula commit, SMR's
    # version id), or, for a script channel that reports nothing, the
    # `run:` line that shipped. Dev adds what it knows itself — the
    # channel, the builds and their ids, the track — and records the whole
    # as a GitHub Deployment (DeploymentRecord); the receipt is the part
    # only the publisher could say.
    #
    # A receipt may add a **hint**: what the operator can do now that it
    # landed (brew's upgrade line), said by the one party that knows —
    # `deploy` prints it last and knows nothing of the channel behind it.
    #
    # Owns the invariant that a receipt says something: an empty summary
    # would record a deploy nobody can read back.
    class Receipt < T::Struct
      extend T::Sig

      # A publisher returned a receipt with nothing in it.
      class EmptyReceiptError < ArgumentError; end

      # @return [String] one line, in the publisher's words
      const :summary, String

      # @return [String, nil] what to do now, in the publisher's words
      const :hint, T.nilable(String)

      # @param summary [String] non-empty
      # @param hint [String, nil]
      # @raise [EmptyReceiptError]
      sig { params(summary: String, hint: T.nilable(String)).void }
      def initialize(summary:, hint: nil)
        super
        raise EmptyReceiptError, "a receipt must say what the publisher did" if summary.strip.empty?
      end

      sig { returns(String) }
      def to_s
        summary
      end

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        other.is_a?(Receipt) && summary == other.summary && hint == other.hint
      end

      sig { params(other: Object).returns(T::Boolean) }
      def eql?(other)
        self == other
      end

      sig { returns(Integer) }
      def hash
        [Receipt, summary, hint].hash
      end
    end
  end
end
