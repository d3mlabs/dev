# typed: strict
# frozen_string_literal: true

module Dev
  module Lifecycle
    # A word outside DeploymentState's set, read back from the forge.
    # Beside the enum rather than inside it: a T::Enum body may hold only
    # its own values.
    class UnknownDeploymentStateError < ArgumentError; end

    # The state of a recorded deploy, as GitHub spells a deployment status.
    # Dev writes `success` when the publisher returned and `failure` when it
    # raised; the rest are GitHub's own vocabulary, which `dev deploy
    # status` must still read. A deployment with no status yet is `pending`.
    class DeploymentState < T::Enum
      extend T::Sig

      enums do
        Success = new("success")
        Failure = new("failure")
        Error = new("error")
        Inactive = new("inactive")
        InProgress = new("in_progress")
        Queued = new("queued")
        Pending = new("pending")
      end

      class << self
        extend T::Sig

        # The state a word names — the deserialization the forge's answers
        # go through.
        #
        # @param word [String]
        # @return [DeploymentState]
        # @raise [UnknownDeploymentStateError]
        sig { params(word: String).returns(DeploymentState) }
        def parse(word)
          try_deserialize(word) ||
            raise(UnknownDeploymentStateError, "unknown deployment state #{word.inspect} (expected #{values.map(&:serialize).join(", ")})")
        end
      end

      # Whether the deploy landed.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def success?
        self == Success
      end

      # Whether the deploy ended without landing.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def failed?
        self == Failure || self == Error
      end

      # The word, for the API or a report.
      #
      # @return [String]
      sig { returns(String) }
      def to_s
        serialize
      end
    end
  end
end
