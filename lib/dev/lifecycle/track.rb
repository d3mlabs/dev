# typed: strict
# frozen_string_literal: true

module Dev
  module Lifecycle
    # A word outside Track's set, at a boundary (a deployment's payload
    # read back from the forge). Beside the enum rather than inside it: a
    # T::Enum body may hold only its own values.
    class UnknownTrackError < ArgumentError; end

    # The track a deploy ships on (dev#192, K5): a channel's protocol takes
    # one — Steam's branch, SMR's unreleased/released, a staging rsync has
    # a single one — and the source decides it, never the operator: an
    # artifact from the **store** goes to the testing track, an archive of
    # a **release** (`deploy --release`, dev#425) to the live one. That is
    # the whole statement of "irreversible channel": a deploy from the
    # store never touches live. Closed, and spelled one way for the
    # publishers, the script env (`DEV_TRACK`) and the receipt (dev#423).
    class Track < T::Enum
      extend T::Sig

      enums do
        Testing = new("testing")
        Live = new("live")
      end

      class << self
        extend T::Sig

        # The track a word names — the deserialization every boundary goes
        # through.
        #
        # @param word [String]
        # @return [Track]
        # @raise [UnknownTrackError]
        sig { params(word: String).returns(Track) }
        def parse(word)
          try_deserialize(word) || raise(UnknownTrackError, "unknown track #{word.inspect} (expected #{values.map(&:serialize).join(", ")})")
        end
      end

      # Whether this is the track a release ships to.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def live?
        self == Live
      end

      # The id, for the env, a payload and the report.
      #
      # @return [String]
      sig { returns(String) }
      def to_s
        serialize
      end
    end
  end
end
