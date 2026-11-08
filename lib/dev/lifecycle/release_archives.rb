# typed: strict
# frozen_string_literal: true

require "digest"
require "pathname"
require_relative "archive"
require_relative "github_releases"
require_relative "manifest"
require_relative "part_list"
require_relative "release_tag"
require_relative "shipment"
require_relative "store"
require_relative "target"

module Dev
  module Lifecycle
    # A cut release read back from the forge for `deploy --release`
    # (dev#192, K4; dev#425): `release.json` first — always fresh, since
    # the release is the truth about itself — then the archives a channel
    # selected from it, each downloaded under its asset name into the
    # store's `.releases/<tag>/` and **verified** against the digest
    # `release.json` records before it ships; a split set's parts the same
    # way against its `MANIFEST`. A file already there that verifies is not
    # downloaded again, so a release fanned out over several channels
    # crosses the wire once; one that does not verify is removed and
    # refused — the deploy ships what the cut made or nothing.
    #
    # The counterpart of ReleaseAssets, which named the archives for the
    # upload: this is the download, and the Shipments it hands back carry
    # the release as their Provenance.
    #
    # The forge, the store and the targets are fixed for a checkout and so
    # are constructor-owned; the tag and the entries are per call.
    class ReleaseArchives
      extend T::Sig

      # The tag has no release on the forge.
      class NoReleaseError < RuntimeError; end

      # The release's `release.json` names another tag than the one it was
      # downloaded from — a release assembled by hand, not by dev.
      class TagMismatchError < RuntimeError; end

      # A downloaded file's digest is not what `release.json` (or, for a
      # split set's part, the `MANIFEST`) records. The file is removed.
      class ChecksumMismatchError < RuntimeError; end

      # @param releases [GithubReleases] the release archive on the forge
      # @param store [Store] whose `.releases/` the downloads land in
      # @param targets [Array<Target>] the project's declared targets, the manifest's grammar
      sig { params(releases: GithubReleases, store: Store, targets: T::Array[Target]).void }
      def initialize(releases:, store:, targets:)
        @releases = releases
        @store = store
        @targets = targets
      end

      # The release's `release.json`, downloaded now.
      #
      # @param tag [ReleaseTag]
      # @return [Manifest::Release]
      # @raise [NoReleaseError]
      # @raise [TagMismatchError]
      # @raise [GithubReleases::Error] a release without `release.json`, a refused read
      # @raise [Manifest::MalformedManifestError]
      sig { params(tag: ReleaseTag).returns(Manifest::Release) }
      def manifest(tag)
        raise NoReleaseError, "#{tag} has no release on the forge — `dev release #{tag.version}` cuts it" if @releases.find(tag).nil?

        dir = @store.release_dir(tag)
        @releases.download(tag, [Manifest::Release::FILE_NAME], into: dir)
        release = Manifest::Release.read(dir, targets: @targets)
        return release if release.tag == tag.name

        raise TagMismatchError,
          "#{tag}'s #{Manifest::Release::FILE_NAME} says it is #{release.tag}: the release was not cut by `dev release`, and is not shipped"
      end

      # The selected archives of a release, on disk and verified.
      #
      # @param entries [Array<Manifest::Release::Archive>] which of the release's archives, in ship order
      # @param release [Manifest::Release] the release they are entries of (ReleaseArchives#manifest)
      # @param tag [ReleaseTag]
      # @return [Array<Shipment>] in the entries' order
      # @raise [ChecksumMismatchError]
      # @raise [GithubReleases::Error] an asset the release no longer has, a refused read
      # @raise [PartList::MalformedPartListError]
      sig { params(entries: T::Array[Manifest::Release::Archive], release: Manifest::Release, tag: ReleaseTag).returns(T::Array[Shipment]) }
      def fetch(entries, release:, tag:)
        dir = @store.release_dir(tag)
        download(entries.map { |entry| [entry.name, entry.sha256] }, into: dir, tag:, recorded_by: Manifest::Release::FILE_NAME)
        entries.map do |entry|
          archive = dir / entry.name
          fetch_parts(archive, into: dir, tag:) if entry.name.end_with?(".#{Archive::Form::Tar::MANIFEST_EXTENSION}")
          Shipment.of_release(entry, archive:, tag:, sha: release.sha)
        end
      end

      private

      # A split set: every part its MANIFEST lists, verified against it.
      #
      # @param manifest [Pathname] the downloaded MANIFEST
      # @param into [Pathname]
      # @param tag [ReleaseTag]
      # @return [void]
      # @raise [ChecksumMismatchError]
      # @raise [PartList::MalformedPartListError]
      sig { params(manifest: Pathname, into: Pathname, tag: ReleaseTag).void }
      def fetch_parts(manifest, into:, tag:)
        parts = PartList.read(manifest).parts.map { |part| [part.name, part.sha256] }
        download(parts, into:, tag:, recorded_by: manifest.basename.to_s)
      end

      # Download what is not already there and verified, then verify all.
      #
      # @param files [Array<[String, String]>] asset name and expected digest
      # @param into [Pathname]
      # @param tag [ReleaseTag]
      # @param recorded_by [String] what records the digests, for the refusal
      # @return [void]
      # @raise [ChecksumMismatchError]
      sig { params(files: T::Array[[String, String]], into: Pathname, tag: ReleaseTag, recorded_by: String).void }
      def download(files, into:, tag:, recorded_by:)
        missing = files.reject { |name, sha256| (into / name).file? && digest(into / name) == sha256 }
        @releases.download(tag, missing.map(&:first), into:)
        files.each { |name, sha256| verify!(into / name, sha256, recorded_by:) }
      end

      # @param file [Pathname]
      # @param sha256 [String] what it must hash to
      # @param recorded_by [String]
      # @return [void]
      # @raise [ChecksumMismatchError]
      sig { params(file: Pathname, sha256: String, recorded_by: String).void }
      def verify!(file, sha256, recorded_by:)
        actual = digest(file)
        return if actual == sha256

        file.delete
        raise ChecksumMismatchError,
          "#{file.basename} hashes to #{actual}, not the #{sha256} its #{recorded_by} records — the download is removed; " \
            "retry, and if it persists the release's asset was altered after the cut"
      end

      # @param file [Pathname]
      # @return [String] its SHA-256, hex
      sig { params(file: Pathname).returns(String) }
      def digest(file) = Digest::SHA256.file(file.to_s).hexdigest
    end
  end
end
