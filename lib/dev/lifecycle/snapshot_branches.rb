# typed: strict
# frozen_string_literal: true

require "stringio"
require "time"
require_relative "git"
require_relative "snapshot_branch"

module Dev
  module Lifecycle
    # The `dev/build/*` namespace on the project's `origin`: where a
    # snapshot is pushed for a remote dispatch, deleted from when the
    # dispatch completes, and pruned from by age when a delete never
    # happened. The retention rule is here and nowhere else; `dev cache gc`
    # runs it.
    class SnapshotBranches
      extend T::Sig

      # The push of a snapshot was refused (no credential, no such remote,
      # a protected namespace).
      class PushError < RuntimeError; end

      # The namespace could not be listed (no `origin`, offline).
      class ListError < RuntimeError; end

      # Expired branches could not be deleted (a read-only credential).
      class DeleteError < RuntimeError; end

      REMOTE = "origin"
      # How long a snapshot branch outlives the dispatch that made it
      # before the prune takes it: long enough to inspect a failed run's
      # exact tree, short enough that branches never pile up.
      MAX_AGE_DAYS = 7
      MAX_AGE = T.let(MAX_AGE_DAYS * 24 * 60 * 60, Integer)

      # @param git [Git] over the checkout whose `origin` holds the namespace
      # @param out [IO, StringIO] where the prune reports
      sig { params(git: Git, out: T.any(IO, StringIO)).void }
      def initialize(git:, out: $stdout)
        @git = git
        @out = out
      end

      # Push a commit to its snapshot branch. Forced: the namespace is
      # dev's and a retry of one dispatch may reuse the branch; `--no-verify`
      # because a project's pre-push hook guards the project's branches,
      # not a throwaway one.
      #
      # @param sha [String] the snapshot commit
      # @param branch [SnapshotBranch]
      # @return [void]
      # @raise [PushError]
      sig { params(sha: String, branch: SnapshotBranch).void }
      def push(sha, branch)
        @git.capture(["push", "--quiet", "--no-verify", "--force", REMOTE, "#{sha}:#{branch.ref}"])
      rescue Git::CommandFailedError => e
        raise PushError, "could not push the snapshot to #{REMOTE} as #{branch}: #{e.message}"
      end

      # Delete snapshot branches from the remote, in one round trip.
      #
      # @param branches [Array<SnapshotBranch>]
      # @return [void]
      # @raise [DeleteError]
      sig { params(branches: T::Array[SnapshotBranch]).void }
      def delete(branches)
        return if branches.empty?

        @git.capture(["push", "--quiet", "--no-verify", REMOTE, "--delete", *branches.map(&:ref)])
      rescue Git::CommandFailedError => e
        raise DeleteError, "could not delete #{branches.join(", ")} from #{REMOTE}: #{e.message}"
      end

      # Every snapshot branch on the remote. A name under the namespace that
      # the sync step did not mint is not dev's and is left out.
      #
      # @return [Array<SnapshotBranch>]
      # @raise [ListError]
      sig { returns(T::Array[SnapshotBranch]) }
      def list
        listing = @git.capture(["ls-remote", "--heads", REMOTE, SnapshotBranch::REFSPEC_GLOB])
        listing.each_line.filter_map do |line|
          ref = line.split("\t", 2).fetch(1, "").strip
          SnapshotBranch.parse(ref)
        rescue SnapshotBranch::MalformedSnapshotBranchError
          nil
        end
      rescue Git::CommandFailedError => e
        raise ListError, "could not list #{SnapshotBranch::NAMESPACE}/* on #{REMOTE}: #{e.message}"
      end

      # Delete every snapshot branch older than the retention, reporting
      # each. Best-effort like the rest of `dev cache gc`'s tiers: a remote
      # that cannot be listed or written (offline, a read-only token in
      # CI's cleanup step) is reported and skipped, never a failure of the
      # gc — the branches wait for the next prune.
      #
      # @param max_age [Integer] seconds
      # @param now [Time]
      # @return [Array<SnapshotBranch>] what was deleted
      sig { params(max_age: Integer, now: Time).returns(T::Array[SnapshotBranch]) }
      def prune(max_age: MAX_AGE, now: Time.now)
        expired = list.select { |branch| branch.older_than?(max_age, now:) }
        delete(expired)
        expired.each { |branch| @out.puts ">>> gc: removed snapshot branch #{branch} from #{REMOTE}" }
        expired
      rescue ListError, DeleteError => e
        @out.puts ">>> gc: skipping snapshot branches — #{e.message}"
        []
      end
    end
  end
end
