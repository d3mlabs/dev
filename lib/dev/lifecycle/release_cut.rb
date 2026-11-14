# typed: strict
# frozen_string_literal: true

require_relative "git"
require_relative "git_state"
require_relative "project_version"
require_relative "release_tag"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # The git half of `release <version>`: a cut is a clean tree, a bump
    # commit when the project keeps its version in source (`VERSION` and
    # its `Gemfile.lock` mirror), the tag, and the push of the branch and
    # the tag to `origin`. Resumable: a run whose cut landed (HEAD already
    # carries the tag) resumes at the push instead of bumping again, so a
    # retry finishes the release and never cuts a second one. A tag that
    # exists on another commit is refused.
    #
    # Three steps, each reading one plan: `bump!` commits the version,
    # `tag!` tags it (`cut!` is both; nothing when resuming), `push!`
    # publishes them. Split so the verb can report what the cut will do
    # before it does it and name each step as it runs. The commit is the
    # operator's own, unlike a snapshot's.
    #
    # The plan also reads the base the release is cut from: HEAD's sha, the
    # previous tag the notes span from, and the drift from the branch's
    # remote-tracking ref as last fetched. The cut never fetches or pulls,
    # so a checkout behind its origin is reported for the operator to weigh
    # at the confirm, not refused.
    class ReleaseCut
      extend T::Sig

      # The project root is not a git checkout with a commit.
      class NotACheckoutError < RuntimeError; end

      # The working tree has uncommitted changes.
      class DirtyTreeError < RuntimeError; end

      # HEAD is not on a branch: there is nothing to push the bump to.
      class DetachedHeadError < RuntimeError; end

      # The release's tag exists and points at another commit.
      class TagElsewhereError < RuntimeError; end

      BUMP_MESSAGE = "Bump version to %<version>s"
      REMOTE = "origin"

      # The bump of the version the project keeps in source.
      class VersionBump < T::Struct
        extend T::Sig
        include Dev::ValueEquality::Derived

        const :from, String
        const :to, String

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [from, to]
        end
      end

      # Where the checkout stands against its branch's remote-tracking
      # ref as last fetched: how many commits it is ahead (unpushed) and
      # behind (merged elsewhere since the last fetch). Both nil when the
      # ref does not exist — origin was never fetched for this branch.
      class Drift < T::Struct
        extend T::Sig
        include Dev::ValueEquality::Derived

        # @return [String] the remote-tracking ref, `origin/main`
        const :upstream, String
        const :ahead, T.nilable(Integer)
        const :behind, T.nilable(Integer)

        # @return [String] the base line's clause
        sig { returns(String) }
        def to_s
          ahead = self.ahead
          behind = self.behind
          return "#{upstream} never fetched" if ahead.nil? || behind.nil?
          return "in sync with #{upstream}" if ahead.zero? && behind.zero?
          return "#{ahead} ahead of #{upstream}, unpushed" if behind.zero?

          "#{ahead.positive? ? "#{ahead} ahead, " : ""}#{behind} behind #{upstream} as last fetched"
        end

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [upstream, ahead, behind]
        end
      end

      # What one run of the cut will do, and from where, read from the
      # checkout before anything moves.
      class Plan < T::Struct
        extend T::Sig
        include Dev::ValueEquality::Derived

        const :tag, ReleaseTag
        # @return [String] the branch HEAD is on — what the push publishes
        const :branch, String
        # @return [String] HEAD's commit — the base the release is cut from
        const :sha, String
        # @return [Boolean] the tag already points at HEAD: nothing to cut,
        #   the run resumes at the push
        const :resuming, T::Boolean
        # @return [VersionBump, nil] nil when the project keeps no version
        #   in source, or already carries this one
        const :bump, T.nilable(VersionBump)
        # @return [String, nil] the previous tag in HEAD's ancestry — what
        #   the notes span from; nil for a first release
        const :previous, T.nilable(String)
        # @return [Array<String>] the commits since the previous tag, one
        #   line each (`git log --oneline`), read before the bump adds its own
        const :commits, T::Array[String]
        # @return [Drift] the checkout against its origin as last fetched
        const :drift, Drift

        # The release notes: the commits, or the stock line for a first
        # release or a tag with nothing since the previous.
        #
        # @return [String]
        sig { returns(String) }
        def notes
          commits.empty? ? "Release #{tag}." : commits.join("\n")
        end

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [tag, branch, sha, resuming, bump, previous, commits, drift]
        end
      end

      # @param git [Git] over the project's checkout
      sig { params(git: Git).void }
      def initialize(git:)
        @git = git
      end

      # Read the checkout and decide what cutting +tag+ means here.
      #
      # @param tag [ReleaseTag]
      # @return [Plan]
      # @raise [NotACheckoutError]
      # @raise [DirtyTreeError]
      # @raise [DetachedHeadError]
      # @raise [TagElsewhereError]
      sig { params(tag: ReleaseTag).returns(Plan) }
      def plan(tag)
        assert_clean!
        branch = @git.capture(["branch", "--show-current"]).strip
        raise DetachedHeadError, "HEAD is not on a branch — check one out; a release is cut from a branch its push can publish" if branch.empty?

        resuming = tagged_at_head?(tag)
        previous = previous_tag(tag)
        Plan.new(
          tag:, branch:, sha: head, resuming:, bump: resuming ? nil : bump_for(tag),
          previous:, commits: commits_since(previous), drift: drift(branch),
        )
      end

      # The local cut: the bump commit, then the tag. Nothing when the
      # plan resumes a cut that landed.
      #
      # @param plan [Plan]
      # @return [void]
      # @raise [Git::CommandFailedError]
      sig { params(plan: Plan).void }
      def cut!(plan)
        bump!(plan)
        tag!(plan)
      end

      # The bump commit, when the plan has a bump: the version written
      # into source — `VERSION` and its `Gemfile.lock` mirror when the
      # lock has one (ProjectVersion.files), so the tree is clean after
      # the cut — committed. Nothing when resuming or when the project
      # keeps no version to bump.
      #
      # @param plan [Plan]
      # @return [void]
      # @raise [Git::CommandFailedError]
      sig { params(plan: Plan).void }
      def bump!(plan)
        bump = plan.bump
        return if plan.resuming || bump.nil?

        files = ProjectVersion.files(@git.root, current: bump.from)
        ProjectVersion.write(@git.root, bump.to)
        @git.capture(["add", "--", *files])
        @git.capture(["commit", "-q", "-m", format(BUMP_MESSAGE, version: bump.to)])
      end

      # The tag on HEAD. Nothing when resuming: it is already there.
      #
      # @param plan [Plan]
      # @return [void]
      # @raise [Git::CommandFailedError]
      sig { params(plan: Plan).void }
      def tag!(plan)
        return if plan.resuming

        @git.capture(["tag", plan.tag.name])
      end

      # Publish the cut: the branch, then the tag. Idempotent — a ref
      # already on `origin` pushes as a no-op — so a resumed run replays
      # it.
      #
      # @param plan [Plan]
      # @return [void]
      # @raise [Git::CommandFailedError]
      sig { params(plan: Plan).void }
      def push!(plan)
        @git.capture(["push", "-q", REMOTE, plan.branch])
        @git.capture(["push", "-q", REMOTE, "refs/tags/#{plan.tag.name}"])
      end

      # The commit a tag points at — what `release.json` records.
      #
      # @param tag [ReleaseTag]
      # @return [String] the full sha
      # @raise [Git::CommandFailedError] when the tag does not exist
      sig { params(tag: ReleaseTag).returns(String) }
      def sha(tag)
        @git.capture(["rev-parse", "--verify", "#{tag.name}^{commit}"]).strip
      end

      private

      # @return [void]
      # @raise [NotACheckoutError]
      # @raise [DirtyTreeError]
      sig { void }
      def assert_clean!
        state = GitState.read(@git.root)
        raise NotACheckoutError, "#{@git.root} is not a git checkout with a commit — a release is cut from one" if state.sha.nil?
        return unless state.dirty

        raise DirtyTreeError,
          "the working tree is not clean — commit or stash first; a release is cut from what is committed:\n" \
            "#{@git.capture(["status", "--porcelain"]).strip}"
      end

      # @param tag [ReleaseTag]
      # @return [Boolean] whether the tag exists and points at HEAD
      # @raise [TagElsewhereError] when it exists and does not
      sig { params(tag: ReleaseTag).returns(T::Boolean) }
      def tagged_at_head?(tag)
        return false unless @git.succeeds?(["rev-parse", "--verify", "--quiet", "refs/tags/#{tag.name}"])

        tagged = sha(tag)
        head = @git.capture(["rev-parse", "HEAD"]).strip
        return true if tagged == head

        raise TagElsewhereError,
          "#{tag} already tags #{tagged[0, GitState::SHORT_SHA_LENGTH]}, not HEAD (#{head[0, GitState::SHORT_SHA_LENGTH]}) — " \
            "that version is cut; release the next one, or check the tagged commit out to resume it"
      end

      # @param tag [ReleaseTag]
      # @return [VersionBump, nil]
      sig { params(tag: ReleaseTag).returns(T.nilable(VersionBump)) }
      def bump_for(tag)
        declared = ProjectVersion.declared(@git.root)
        return nil if declared.nil? || declared == tag.version

        VersionBump.new(from: declared, to: tag.version)
      end

      # @return [String] HEAD's commit
      sig { returns(String) }
      def head
        @git.capture(["rev-parse", "HEAD"]).strip
      end

      # The nearest tag in HEAD's ancestry other than the release's own
      # (the resume case: it already tags HEAD), or nil for a first release.
      #
      # @param tag [ReleaseTag]
      # @return [String, nil]
      sig { params(tag: ReleaseTag).returns(T.nilable(String)) }
      def previous_tag(tag)
        argv = ["describe", "--tags", "--abbrev=0", "--exclude", tag.name, "HEAD"]
        return nil unless @git.succeeds?(argv)

        @git.capture(argv).strip
      end

      # @param previous [String, nil] the tag the log starts after
      # @return [Array<String>] `git log --oneline` since it; empty for a
      #   first release (its whole history is not release notes)
      sig { params(previous: T.nilable(String)).returns(T::Array[String]) }
      def commits_since(previous)
        return [] if previous.nil?

        @git.capture(["log", "--oneline", "#{previous}..HEAD"]).lines(chomp: true).reject(&:empty?)
      end

      # The branch against `origin/<branch>` as the checkout last saw it:
      # `rev-list --left-right --count` over the symmetric difference,
      # left the remote's commits HEAD lacks (behind), right HEAD's the
      # remote lacks (ahead). No fetch.
      #
      # @param branch [String]
      # @return [Drift]
      sig { params(branch: String).returns(Drift) }
      def drift(branch)
        upstream = "#{REMOTE}/#{branch}"
        return Drift.new(upstream:, ahead: nil, behind: nil) unless @git.succeeds?(["rev-parse", "--verify", "--quiet", "refs/remotes/#{upstream}"])

        behind, ahead = @git.capture(["rev-list", "--left-right", "--count", "#{upstream}...HEAD"]).split.map(&:to_i)
        Drift.new(upstream:, ahead:, behind:)
      end
    end
  end
end
