# typed: strict
# frozen_string_literal: true

require_relative "snapshot"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # What a build host holds of the project's tree for the duration of a
    # run: the transport's delivery, as the host sees it — enough to name
    # on the crossing line and for the host's side to run the verb in. The
    # transport that delivered it is the one that reads it back; the
    # callers between see only its `description`.
    #
    # Sealed: a host holds the tree in one of the shapes declared here,
    # and the side that runs in it cases over them with a T.absurd proof.
    module Workspace
      extend T::Sig
      extend T::Helpers
      # Every includer is an Object; this tells Sorbet the Object protocol
      # exists on a value typed as the interface.
      include Kernel
      abstract!
      sealed!

      # The workspace as the crossing line names it, after the destination:
      # `snapshot 3f2a1c9d8e7b`.
      #
      # @return [String]
      sig { abstract.returns(String) }
      def description; end

      # The tree as a snapshot branch on the forge, which the host fetches
      # for itself — a runner job's checkout, the container's own workspace
      # under its data root. What the sync step pushed, carried across the
      # seam.
      class Snapshot
        extend T::Sig
        extend T::Helpers
        include Workspace
        include Dev::ValueEquality::Derived
        final!

        # @return [Lifecycle::Snapshot] the commit, and the ref the forge serves it at
        sig(:final) { returns(Lifecycle::Snapshot) }
        attr_reader :snapshot

        # @param snapshot [Lifecycle::Snapshot] what the sync step pushed
        sig(:final) { params(snapshot: Lifecycle::Snapshot).void }
        def initialize(snapshot)
          @snapshot = snapshot
        end

        sig(:final) { override.returns(String) }
        def description
          "snapshot #{@snapshot.short_sha}"
        end

        # @return [Array] the members that constitute identity
        sig(:final) { override.returns(T::Array[T.anything]) }
        def equality_members
          [@snapshot]
        end
      end
    end
  end
end
