# typed: strict
# frozen_string_literal: true

module Dev
  module Lifecycle
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

      # The id, for the env and the report.
      #
      # @return [String]
      sig { returns(String) }
      def to_s = serialize
    end
  end
end
