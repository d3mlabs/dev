# typed: strict
# frozen_string_literal: true

require "digest"
require "pathname"
require_relative "archive"
require_relative "artifact"
require_relative "manifest"
require_relative "part_list"
require_relative "release_tag"

module Dev
  module Lifecycle
    # The assets a release attaches for one artifact (dev#192, K4): the
    # archive under its release name, `<build>-<version>.<ext>` — the
    # store's `<build>.<ext>` with the version after the build — gathered
    # into one directory the upload reads from. The archive is never
    # copied or rewritten: the asset is a symlink to the file in the
    # store, named as the release names it, and its digest is the one
    # `build-id.json` stamped. The one exception is the split tar form,
    # whose archive is a `MANIFEST` listing its parts by name: the parts
    # are linked under their release names and a MANIFEST naming them is
    # written beside, so what a reader downloads reads as one set.
    #
    # The gathering directory is the caller's (a temporary one, gone after
    # the upload); nothing here persists.
    class ReleaseAssets
      extend T::Sig

      # An archive file whose name does not start with its build's name —
      # a packager that broke the `<build>.<ext>` contract.
      class UnnamedArchiveError < RuntimeError; end

      # What one artifact contributes to a release: its `release.json`
      # entry and the files to upload, the archive first.
      class Gathered < T::Struct
        const :archive, Manifest::Release::Archive
        const :files, T::Array[Pathname]
      end

      # @param dir [Pathname] where the assets are gathered; created on first use
      sig { params(dir: Pathname).void }
      def initialize(dir:)
        @dir = dir
      end

      # Gather one artifact's assets under their release names.
      #
      # @param artifact [Artifact] as the store holds it
      # @param tag [ReleaseTag] the release the assets are named for
      # @return [Gathered]
      # @raise [UnnamedArchiveError]
      # @raise [PartList::MalformedPartListError]
      sig { params(artifact: Artifact, tag: ReleaseTag).returns(Gathered) }
      def gather(artifact, tag:)
        @dir.mkpath
        name = asset_name(artifact.manifest.archive, artifact:, tag:)
        split = artifact.manifest.archive.end_with?(".#{Archive::Form::Tar::MANIFEST_EXTENSION}")
        files, sha256 = split ? gather_split(artifact, name, tag:) : [[link(artifact.archive, name)], artifact.manifest.archive_sha256]
        entry = Manifest::Release::Archive.new(build: artifact.build, name:, sha256:, build_id: artifact.manifest.build_id)
        Gathered.new(archive: entry, files:)
      end

      private

      # The release name of one of an artifact's files: the version after
      # the build's name, the extension kept.
      #
      # @param file_name [String] `<build>.<ext>`
      # @param artifact [Artifact]
      # @param tag [ReleaseTag]
      # @return [String] `<build>-<version>.<ext>`
      # @raise [UnnamedArchiveError]
      sig { params(file_name: String, artifact: Artifact, tag: ReleaseTag).returns(String) }
      def asset_name(file_name, artifact:, tag:)
        prefix = "#{artifact.name}."
        unless file_name.start_with?(prefix) && file_name.length > prefix.length
          raise UnnamedArchiveError,
            "#{artifact.dir}: the archive '#{file_name}' is not named for its build ('#{prefix}<ext>'); package it again"
        end

        "#{artifact.name}-#{tag.version}.#{file_name.delete_prefix(prefix)}"
      end

      # A split archive: each part linked under its release name, and a
      # MANIFEST naming them written in the gathering directory.
      #
      # @param artifact [Artifact]
      # @param manifest_name [String] the MANIFEST's release name
      # @param tag [ReleaseTag]
      # @return [Array(Array<Pathname>, String)] the files (the MANIFEST
      #   first) and the written MANIFEST's digest
      # @raise [PartList::MalformedPartListError]
      sig { params(artifact: Artifact, manifest_name: String, tag: ReleaseTag).returns([T::Array[Pathname], String]) }
      def gather_split(artifact, manifest_name, tag:)
        listed = PartList.read(artifact.archive)
        assets = listed.parts.map { |part| link(artifact.dir / part.name, asset_name(part.name, artifact:, tag:)) }
        manifest = @dir / manifest_name
        listed.renamed { |name| asset_name(name, artifact:, tag:) }.write(manifest)
        [[manifest, *assets], Digest::SHA256.file(manifest.to_s).hexdigest]
      end

      # @param source [Pathname] a file in the store
      # @param name [String] its release name
      # @return [Pathname] the link in the gathering directory
      sig { params(source: Pathname, name: String).returns(Pathname) }
      def link(source, name)
        asset = @dir / name
        asset.delete if asset.symlink? || asset.file?
        asset.make_symlink(source.expand_path)
        asset
      end
    end
  end
end
