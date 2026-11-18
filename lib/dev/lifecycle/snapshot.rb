# typed: strict
# frozen_string_literal: true

require_relative "snapshot_branch"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # A working-tree snapshot as the remote side can reach it: the commit,
    # and the ref the forge serves it at. Two ways to be one:
    #
    # - **pushed** — the sync step committed the tree and pushed it to a
    #   `SnapshotBranch` of dev's own; `ref` is that branch's, and the
    #   branch is what a `workflow_dispatch` names and the sync deletes
    #   after.
    # - **checked out** — an Actions job's own checkout, already on the
    #   forge at the job's ref (`refs/pull/<n>/merge`, `refs/heads/main`);
    #   nothing was pushed, there is no branch, and nothing is deleted.
    #
    # Either way the sha is what the crossing line prints and the container
    # resets to, and the ref is what it fetches.
    class Snapshot
      extend T::Sig
      include Dev::ValueEquality::Derived

      # @return [String] the full commit sha
      sig { returns(String) }
      attr_reader :sha

      # @return [String] the ref the forge serves the commit at
      sig { returns(String) }
      attr_reader :ref

      # @return [SnapshotBranch, nil] the branch the sync pushed; nil for a
      #   checked-out snapshot
      sig { returns(T.nilable(SnapshotBranch)) }
      attr_reader :branch

      class << self
        extend T::Sig

        # An Actions job's checkout as the forge already has it.
        #
        # @param sha [String]
        # @param ref [String] the job's ref (`GITHUB_REF`)
        # @return [Snapshot]
        sig { params(sha: String, ref: String).returns(Snapshot) }
        def checked_out(sha:, ref:)
          new(sha:, ref:)
        end
      end

      # @param sha [String] the full commit sha
      # @param branch [SnapshotBranch, nil] the pushed branch; its ref is the snapshot's
      # @param ref [String, nil] the ref, for a snapshot with no branch
      # @raise [ArgumentError] neither or both of branch and ref
      sig { params(sha: String, branch: T.nilable(SnapshotBranch), ref: T.nilable(String)).void }
      def initialize(sha:, branch: nil, ref: nil)
        raise ArgumentError, "a snapshot is pushed to a branch or checked out at a ref, not both" if branch && ref
        raise ArgumentError, "a snapshot needs the branch it was pushed to or the ref it is checked out at" if branch.nil? && ref.nil?

        @sha = sha
        @branch = branch
        @ref = T.let(ref || T.must(branch).ref, String)
      end

      # @return [Boolean] whether the sync pushed this snapshot (and owns a
      #   branch to delete), as opposed to handing over a job's checkout
      sig { returns(T::Boolean) }
      def pushed?
        !@branch.nil?
      end

      # @return [String] the sha as the crossing line prints it
      sig { returns(String) }
      def short_sha
        T.must(sha[0, 12])
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [sha, ref, branch]
      end
    end
  end
end
