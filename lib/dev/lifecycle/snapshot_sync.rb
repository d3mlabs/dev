# typed: strict
# frozen_string_literal: true

require "pathname"
require "stringio"
require_relative "git"
require_relative "snapshot"
require_relative "snapshot_branch"
require_relative "snapshot_branches"
require_relative "snapshot_commit"
require_relative "workflow_triggers"

module Dev
  module Lifecycle
    # The sync step of the remote dispatch: make the working tree reachable
    # from a build host as a snapshot branch for exactly as long as the
    # dispatch needs it. In order: refuse while nothing has left the
    # machine if a project workflow would run on the push, commit the tree
    # through a temporary index, push the commit to
    # `dev/build/<runner>/<id>`, hand the snapshot to the dispatch, and
    # delete the branch when the dispatch returns, however it returns.
    #
    # The delete is best-effort: a build that succeeded is not failed by a
    # lost connection afterwards, and SnapshotBranches' retention rule
    # takes the branch on the next `dev cache gc`.
    class SnapshotSync
      extend T::Sig

      # @param root [Pathname] the project root
      # @param git [Git] over that root
      # @param triggers [WorkflowTriggers] the project's workflows
      # @param commit [SnapshotCommit] the temp-index commit
      # @param branches [SnapshotBranches] the remote namespace
      # @param out [IO, StringIO] where a failed delete is reported
      sig do
        params(
          root: Pathname,
          git: Git,
          triggers: WorkflowTriggers,
          commit: SnapshotCommit,
          branches: SnapshotBranches,
          out: T.any(IO, StringIO),
        ).void
      end
      def initialize(
        root:,
        git: Git.new(root:),
        triggers: WorkflowTriggers.new(root:),
        commit: SnapshotCommit.new(git:),
        branches: SnapshotBranches.new(git:),
        out: $stderr
      )
        @root = root
        @triggers = triggers
        @commit = commit
        @branches = branches
        @out = out
      end

      # Push a snapshot of the working tree for a dispatch to a runner, run
      # the dispatch with it, and delete the branch after.
      #
      # @param runner [String] the runner label the branch is named for
      # @yieldparam snapshot [Snapshot] the pushed commit and its branch
      # @yieldreturn [R] what the dispatch returns
      # @return [R] the block's value
      # @raise [WorkflowTriggers::UnfilteredPushTriggerError] before anything is pushed
      # @raise [SnapshotBranch::InvalidRunnerLabelError]
      # @raise [SnapshotCommit::NotACheckoutError]
      # @raise [SnapshotBranches::PushError]
      sig do
        type_parameters(:R)
          .params(runner: String, blk: T.proc.params(snapshot: Snapshot).returns(T.type_parameter(:R)))
          .returns(T.type_parameter(:R))
      end
      def sync(runner:, &blk)
        branch = SnapshotBranch.mint(runner:)
        @triggers.assert_none_fire_on_push_to!(branch.name)
        sha = @commit.create
        @branches.push(sha, branch)
        begin
          yield Snapshot.new(sha:, branch:)
        ensure
          delete_quietly(branch)
        end
      end

      private

      # @param branch [SnapshotBranch]
      # @return [void]
      sig { params(branch: SnapshotBranch).void }
      def delete_quietly(branch)
        @branches.delete([branch])
      rescue SnapshotBranches::DeleteError => e
        @out.puts "#{e.message}; `dev cache gc` prunes it after #{SnapshotBranches::MAX_AGE_DAYS} days"
      end
    end
  end
end
