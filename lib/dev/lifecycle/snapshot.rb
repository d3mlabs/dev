# typed: strict
# frozen_string_literal: true

require_relative "snapshot_branch"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # A working-tree snapshot as the remote side can reach it: the commit
    # the sync step made of the tree, and the `SnapshotBranch` of dev's own
    # it pushed the commit to — the branch a `workflow_dispatch` names and
    # the sync deletes after. The sha is what the crossing line prints; the
    # branch's ref is what the host fetches.
    class Snapshot
      extend T::Sig
      include Dev::ValueEquality::Derived

      # @return [String] the full commit sha
      sig { returns(String) }
      attr_reader :sha

      # @return [SnapshotBranch] the branch the sync pushed
      sig { returns(SnapshotBranch) }
      attr_reader :branch

      # @param sha [String] the full commit sha
      # @param branch [SnapshotBranch] the pushed branch; its ref is the snapshot's
      sig { params(sha: String, branch: SnapshotBranch).void }
      def initialize(sha:, branch:)
        @sha = sha
        @branch = branch
      end

      # @return [String] the ref the forge serves the commit at
      sig { returns(String) }
      def ref
        @branch.ref
      end

      # @return [String] the sha as the crossing line prints it
      sig { returns(String) }
      def short_sha
        T.must(sha[0, 12])
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [sha, branch]
      end
    end
  end
end
