# typed: strict
# frozen_string_literal: true

module Dev
  module Lifecycle
    # A word outside Track's set, at a boundary (a deployment's payload
    # read back from the forge). Beside the enum rather than inside it: a
    # T::Enum body may hold only its own values.
    class UnknownTrackError < ArgumentError; end

    # Which track of a channel a deploy lands on (dev#192, K5): a channel's
    # protocol takes one — Steam's branch, SMR's unreleased vs released, a
    # staging rsync has only one — and dev decides it from the **source** of
    # what ships, never from a flag. A working artifact from the store goes
    # to the *testing* track; a release's archive (`deploy --release`,
    # dev#425) to the *live* one. That rule is the whole statement of
    # "irreversible channel": a deploy from the store never touches live.
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
      def live? = self == Live

      # The word, for a payload or a report.
      #
      # @return [String]
      sig { returns(String) }
      def to_s = serialize
    end
  end
end
