# typed: strict
# frozen_string_literal: true

require "pathname"

module Dev
  module Lifecycle
    # What `--fetch` asks of a remote dispatch (dev#192, K10): bring the
    # artifact the remote `package` stamped back into this machine's
    # store. The artifact crosses as a workflow artifact named after the
    # build — the generic workflow uploads the archive and its
    # `build-id.json` under that name — and lands in the store directory
    # the build has here, so `dev deploy` on this machine reads it as if
    # it had been packaged here. The default is the opposite (nothing
    # comes back): a multi-GB archive over a Mac's uplink is wanted only
    # when a deploy leaves from the Mac.
    class ArtifactFetch < T::Struct
      extend T::Sig

      # @return [String] the workflow artifact's name: the build's
      const :name, String
      # @return [Pathname] the store directory the files land in
      const :into, Pathname

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        other.is_a?(ArtifactFetch) && name == other.name && into == other.into
      end

      sig { params(other: Object).returns(T::Boolean) }
      def eql?(other)
        self == other
      end

      sig { returns(Integer) }
      def hash
        [ArtifactFetch, name, into].hash
      end
    end
  end
end
