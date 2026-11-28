# typed: strict
# frozen_string_literal: true

require "pathname"
require "time"
require "tmpdir"
require_relative "github_releases"
require_relative "manifest"
require_relative "release_tag"
require_relative "target"

module Dev
  module Lifecycle
    # The `release.json` of a release being cut, as the draft on the forge
    # carries it. Each `package --attach` records its build's entry into
    # it from wherever the build was packaged — the ledger is read back,
    # the build's entry replaced or added, the whole uploaded in place —
    # so the facts of a release cross back from the hosts as one file,
    # never the bytes. `release` reads the ledger before publishing, checks
    # every build's entry is the tag's, and completes it: the final
    # `release.json`, stamped now, the tag's commit as the cut knows it,
    # the entries in release order.
    #
    # Each record uploads the ledger after the build's assets, so an entry
    # on the ledger means its assets are on the release. The upload
    # clobbers: a retry's record replaces the last run's.
    class ReleaseLedger
      extend T::Sig

      FILE_NAME = Manifest::Release::FILE_NAME

      # @param releases [GithubReleases] the release archive on the forge
      # @param targets [Array<Target>] the project's declared targets, the manifest's grammar
      # @param clock [Proc] the stamp's instant (injectable for tests)
      sig { params(releases: GithubReleases, targets: T::Array[Target], clock: T.proc.returns(Time)).void }
      def initialize(releases:, targets:, clock: -> { Time.now })
        @releases = releases
        @targets = targets
        @clock = clock
      end

      # The ledger as the forge holds it now.
      #
      # @param tag [ReleaseTag]
      # @return [Manifest::Release, nil] nil when no attach has recorded yet
      # @raise [GithubReleases::AssetMissingError] a tag with no release
      # @raise [GithubReleases::Error] a refused read
      # @raise [Manifest::MalformedManifestError]
      sig { params(tag: ReleaseTag).returns(T.nilable(Manifest::Release)) }
      def read(tag)
        return nil unless @releases.asset_names(tag).include?(FILE_NAME)

        Dir.mktmpdir("dev-ledger-") do |tmp|
          dir = Pathname(tmp)
          @releases.download(tag, [FILE_NAME], into: dir)
          Manifest::Release.read(dir, targets: @targets)
        end
      end

      # Record one build's entry: the ledger as it stands with this build's
      # entry replaced or added, uploaded in place.
      #
      # @param tag [ReleaseTag]
      # @param entry [Manifest::Release::Archive] the build's entry
      # @param sha [String] the commit the build was packaged at
      # @return [Manifest::Release] the ledger as uploaded
      # @raise [GithubReleases::Error] a refused read or write
      # @raise [Manifest::MalformedManifestError]
      sig { params(tag: ReleaseTag, entry: Manifest::Release::Archive, sha: String).returns(Manifest::Release) }
      def record(tag, entry, sha:)
        recorded = read(tag)&.archives || []
        write(tag, sha:, archives: recorded.reject { |other| other.build == entry.build } + [entry])
      end

      # Complete the ledger for publishing: the tag's commit, the entries
      # in release order, stamped now.
      #
      # @param tag [ReleaseTag]
      # @param sha [String] the tag's commit
      # @param archives [Array<Manifest::Release::Archive>] every release build's entry, in order
      # @return [Manifest::Release] the final `release.json`
      # @raise [GithubReleases::Error] a refused write
      sig { params(tag: ReleaseTag, sha: String, archives: T::Array[Manifest::Release::Archive]).returns(Manifest::Release) }
      def complete(tag, sha:, archives:)
        write(tag, sha:, archives:)
      end

      private

      # @param tag [ReleaseTag]
      # @param sha [String]
      # @param archives [Array<Manifest::Release::Archive>]
      # @return [Manifest::Release] what was uploaded
      # @raise [GithubReleases::Error]
      sig { params(tag: ReleaseTag, sha: String, archives: T::Array[Manifest::Release::Archive]).returns(Manifest::Release) }
      def write(tag, sha:, archives:)
        manifest = Manifest::Release.new(stamp: Manifest::Stamp.now(now: @clock.call), tag: tag.name, sha:, archives:)
        Dir.mktmpdir("dev-ledger-") do |tmp|
          dir = Pathname(tmp)
          manifest.write(dir)
          @releases.upload(tag, [dir / FILE_NAME])
        end
        manifest
      end
    end
  end
end
