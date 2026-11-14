# typed: strict
# frozen_string_literal: true

require "tmpdir"
require_relative "git"

module Dev
  module Lifecycle
    # A snapshot commit of the working tree as it is (tracked files as
    # modified, new files, deletions, `.gitignore` honoured), made through
    # a temporary index so HEAD, the branch and the operator's own index
    # are untouched.
    #
    # A clean tree snapshots to HEAD itself, so the artifact the runner
    # stamps names the commit the operator is at.
    class SnapshotCommit
      extend T::Sig

      # The root is not inside a git checkout: there is nothing to snapshot.
      class NotACheckoutError < RuntimeError; end

      # The snapshot's identity. Fixed rather than the operator's `user.*`
      # so the step works on a host with no git identity configured.
      IDENTITY_ENV = T.let(
        {
          "GIT_AUTHOR_NAME" => "dev",
          "GIT_AUTHOR_EMAIL" => "dev@d3mlabs",
          "GIT_COMMITTER_NAME" => "dev",
          "GIT_COMMITTER_EMAIL" => "dev@d3mlabs",
        }.freeze,
        T::Hash[String, String],
      )

      # @param git [Git] over the checkout to snapshot
      sig { params(git: Git).void }
      def initialize(git:)
        @git = git
      end

      # Commit the working tree and return the commit's sha; the commit is
      # reachable from no ref until it is pushed.
      #
      # @return [String] the full sha — HEAD's for a clean tree
      # @raise [NotACheckoutError]
      # @raise [Git::CommandFailedError]
      sig { returns(String) }
      def create
        raise NotACheckoutError, "#{@git.root} is not a git checkout; nothing to snapshot" unless @git.succeeds?(["rev-parse", "--git-dir"])

        head = head_sha
        Dir.mktmpdir("dev-snapshot-index-") do |dir|
          index_env = { "GIT_INDEX_FILE" => File.join(dir, "index") }
          # Seeded from HEAD so a tracked file that `.gitignore` also names
          # stays in the snapshot, as it is in the branch.
          @git.capture(["read-tree", head], env: index_env) if head
          @git.capture(["add", "--all"], env: index_env)
          tree = @git.capture(["write-tree"], env: index_env).strip
          commit(tree, parent: head)
        end
      end

      private

      # @return [String, nil] HEAD's sha; nil in a repository with no commit yet
      sig { returns(T.nilable(String)) }
      def head_sha
        return unless @git.succeeds?(["rev-parse", "--verify", "--quiet", "HEAD"])

        @git.capture(["rev-parse", "HEAD"]).strip
      end

      # @param tree [String] the snapshot's tree sha
      # @param parent [String, nil] HEAD, when there is one
      # @return [String] the commit sha
      sig { params(tree: String, parent: T.nilable(String)).returns(String) }
      def commit(tree, parent:)
        return parent if parent && tree == @git.capture(["rev-parse", "#{parent}^{tree}"]).strip

        parent_args = parent ? ["-p", parent] : []
        message = parent ? "dev snapshot of the working tree at #{parent[0, 12]}" : "dev snapshot of the working tree"
        @git.capture(["commit-tree", tree, *parent_args, "-m", message], env: IDENTITY_ENV).strip
      end
    end
  end
end
