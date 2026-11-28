# typed: strict
# frozen_string_literal: true

require "pathname"
require "tmpdir"
require_relative "artifact"
require_relative "git_state"
require_relative "github_releases"
require_relative "manifest"
require_relative "project_version"
require_relative "release_assets"
require_relative "release_ledger"
require_relative "release_tag"

module Dev
  module Lifecycle
    # The attach half of `package --attach <version>`: one artifact onto
    # the GitHub release of its tag, from the host that packaged it. The
    # archive goes up under its release name (ReleaseAssets: a split set's
    # parts and rewritten `MANIFEST`), then the build's entry is recorded
    # in the release's ledger (ReleaseLedger), so an entry on the ledger
    # means its assets are on. Uploads clobber: a retry replaces what a
    # failed run half-attached.
    #
    # One rule, enforced where the data is: a release attaches what was
    # packaged from a clean tree at its tag. Before the build runs, the
    # tree must be clean, its `VERSION` (when it keeps one) the tag's, and
    # the release must exist on the forge — the cut creates it before any
    # build is packaged. The tag's commit itself is the cut's to check: it
    # reads the entry's build id back against the tag before publishing.
    class ReleaseAttachment
      extend T::Sig

      # The tree is not the release's: uncommitted changes, or a `VERSION`
      # that is not the tag's.
      class NotAtReleaseError < RuntimeError; end

      # The tag has no release on the forge to attach to.
      class NoReleaseError < RuntimeError; end

      # @param releases [GithubReleases] the release archive on the forge
      # @param ledger [ReleaseLedger] the release's `release.json` as the draft carries it
      sig { params(releases: GithubReleases, ledger: ReleaseLedger).void }
      def initialize(releases:, ledger:)
        @releases = releases
        @ledger = ledger
      end

      # Refuse before anything is built when the artifact could not be
      # the release's.
      #
      # @param tag [ReleaseTag]
      # @param state [GitState] the tree as it is now
      # @param version [String, nil] the version the project keeps in source; nil when none
      # @return [void]
      # @raise [NotAtReleaseError]
      # @raise [NoReleaseError]
      # @raise [GithubReleases::Error] a refused read
      sig { params(tag: ReleaseTag, state: GitState, version: T.nilable(String)).void }
      def assert_attachable!(tag, state:, version:)
        assert_clean!(tag, state)
        if version && version != tag.version
          raise NotAtReleaseError,
            "#{ProjectVersion::FILE_NAME} reads #{version}, not #{tag.version}: the tree is not at #{tag} — " \
              "a release attaches what was packaged at its tag"
        end
        return unless @releases.find(tag).nil?

        raise NoReleaseError, "#{tag} has no release on the forge to attach to — `dev release #{tag.version}` creates it, then attaches"
      end

      # Attach one artifact: its assets, then its entry on the ledger.
      #
      # @param artifact [Artifact] as the store holds it, just stamped
      # @param tag [ReleaseTag]
      # @return [Manifest::Release::Archive] the entry recorded
      # @raise [NotAtReleaseError] the artifact's stamp is not from a clean tree
      # @raise [GithubReleases::FrozenError] the release is published and immutable
      # @raise [GithubReleases::Error] a refused write
      # @raise [ReleaseAssets::UnnamedArchiveError]
      sig { params(artifact: Artifact, tag: ReleaseTag).returns(Manifest::Release::Archive) }
      def attach(artifact, tag:)
        state = artifact.manifest.state
        assert_clean!(tag, state)
        Dir.mktmpdir("dev-attach-") do |tmp|
          gathered = ReleaseAssets.new(dir: Pathname(tmp)).gather(artifact, tag:)
          @releases.upload(tag, gathered.files)
          @ledger.record(tag, gathered.archive, sha: T.must(state.sha))
          gathered.archive
        end
      end

      private

      # @param tag [ReleaseTag]
      # @param state [GitState]
      # @return [void]
      # @raise [NotAtReleaseError]
      sig { params(tag: ReleaseTag, state: GitState).void }
      def assert_clean!(tag, state)
        return if state.clean?

        raise NotAtReleaseError,
          "the tree is #{state.sha.nil? ? "not a checkout" : "not clean"}: an artifact packaged from it is not #{tag}'s — " \
            "a release attaches what was packaged from a clean tree at its tag"
      end
    end
  end
end
