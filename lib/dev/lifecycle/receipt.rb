# typed: strict
# frozen_string_literal: true

require_relative "../value_equality"

module Dev
  module Lifecycle
    # What a publisher says of the upload it made: the destination's own
    # handle on what landed (a Steam build id, the formula commit, SMR's
    # version id), or for a script channel the `run:` line that shipped.
    # Dev adds the channel, the builds and the track and records the whole
    # as a GitHub Deployment.
    #
    # A receipt may add a hint: what the operator can do now that it landed.
    # `deploy` prints it last.
    #
    # Owns the invariant that a receipt says something: an empty summary
    # would record a deploy nobody can read back.
    class Receipt < T::Struct
      extend T::Sig
      include Dev::ValueEquality::Derived

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

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [summary, hint]
      end
    end
  end
end
