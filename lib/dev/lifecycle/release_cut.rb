# typed: strict
# frozen_string_literal: true

require_relative "git"
require_relative "git_state"
require_relative "project_version"
require_relative "release_tag"

module Dev
  module Lifecycle
    # The git half of `release <version>` (dev#192, K4), lifted from dev's
    # `bin/release.rb`: a **cut** is a clean tree, a bump commit when the
    # project keeps its version in source (`VERSION`, ProjectVersion), the
    # tag, and the push of the branch and the tag to `origin`. Resumable:
    # a run whose cut landed (HEAD already carries the tag) resumes at the
    # push instead of bumping again — a retry finishes the release, it
    # never cuts a second one, which is how a failed tap push once turned
    # 0.2.99 into an empty 0.2.100. A tag that exists on another commit is
    # refused: that version was cut from somewhere else.
    #
    # Two steps, each reading one plan: `cut!` moves the local tree
    # (nothing when resuming), `push!` publishes it — split so the verb
    # can report what the cut will do before it does it, and so a push
    # that fails leaves the local cut for the retry to resume. Every git
    # call goes through Git over the checkout; the commit is the
    # operator's own (their identity, their branch), unlike a snapshot's.
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

        const :from, String
        const :to, String

        sig { params(other: Object).returns(T::Boolean) }
        def ==(other) = other.is_a?(VersionBump) && from == other.from && to == other.to

        sig { params(other: Object).returns(T::Boolean) }
        def eql?(other) = self == other

        sig { returns(Integer) }
        def hash = [VersionBump, from, to].hash
      end

      # What one run of the cut will do, read from the checkout before
      # anything moves.
      class Plan < T::Struct
        extend T::Sig

        const :tag, ReleaseTag
        # @return [String] the branch HEAD is on — what the push publishes
        const :branch, String
        # @return [Boolean] the tag already points at HEAD: nothing to cut,
        #   the run resumes at the push
        const :resuming, T::Boolean
        # @return [VersionBump, nil] nil when the project keeps no version
        #   in source, or already carries this one
        const :bump, T.nilable(VersionBump)
        # @return [String] the release notes: the commits since the previous
        #   tag, read before the bump adds its own
        const :notes, String

        sig { params(other: Object).returns(T::Boolean) }
        def ==(other)
          other.is_a?(Plan) && tag == other.tag && branch == other.branch && resuming == other.resuming &&
            bump == other.bump && notes == other.notes
        end

        sig { params(other: Object).returns(T::Boolean) }
        def eql?(other) = self == other

        sig { returns(Integer) }
        def hash = [Plan, tag, branch, resuming, bump, notes].hash
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
        Plan.new(tag:, branch:, resuming:, bump: resuming ? nil : bump_for(tag), notes: notes_since_previous_tag(tag))
      end

      # The local cut: the bump commit, then the tag. Nothing when the
      # plan resumes.
      #
      # @param plan [Plan]
      # @return [void]
      # @raise [Git::CommandFailedError]
      sig { params(plan: Plan).void }
      def cut!(plan)
        return if plan.resuming

        bump = plan.bump
        if bump
          ProjectVersion.write(@git.root, bump.to)
          @git.capture(["add", ProjectVersion::FILE_NAME])
          @git.capture(["commit", "-q", "-m", format(BUMP_MESSAGE, version: bump.to)])
        end
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
      def sha(tag) = @git.capture(["rev-parse", "--verify", "#{tag.name}^{commit}"]).strip

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

      # The one-line log since the previous tag — the release's own tag
      # excluded, so a resumed run reads the same span — or a stock line
      # for a first release.
      #
      # @param tag [ReleaseTag]
      # @return [String]
      sig { params(tag: ReleaseTag).returns(String) }
      def notes_since_previous_tag(tag)
        return "Release #{tag}." unless @git.succeeds?(["describe", "--tags", "--abbrev=0", "--exclude", tag.name, "HEAD"])

        previous = @git.capture(["describe", "--tags", "--abbrev=0", "--exclude", tag.name, "HEAD"]).strip
        log = @git.capture(["log", "--oneline", "#{previous}..HEAD"]).strip
        log.empty? ? "Release #{tag}." : log
      end
    end
  end
end
