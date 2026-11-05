# typed: strict
# frozen_string_literal: true

require_relative "snapshot_branch"

module Dev
  module Lifecycle
    # A working-tree snapshot as the remote side can reach it: the commit
    # and the branch it was pushed to (dev#192, K7). What SnapshotSync
    # hands the dispatch for the time the branch exists — the `ref` a
    # `workflow_dispatch` names, the sha the crossing line prints and the
    # container fetches.
    class Snapshot < T::Struct
      extend T::Sig

      # @return [String] the full commit sha
      const :sha, String
      const :branch, SnapshotBranch

      # @return [String] the sha as the crossing line prints it
      sig { returns(String) }
      def short_sha = T.must(sha[0, 12])

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other) = other.is_a?(Snapshot) && sha == other.sha && branch == other.branch

      sig { params(other: Object).returns(T::Boolean) }
      def eql?(other) = self == other

      sig { returns(Integer) }
      def hash = [Snapshot, sha, branch].hash
    end
  end
end
