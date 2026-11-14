# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "../data_root"
require_relative "artifact"
require_relative "build"
require_relative "channel"
require_relative "manifest"
require_relative "release_tag"
require_relative "target"

module Dev
  module Lifecycle
    # The artifact store of one project: `<data root>/artifacts/<project>/
    # <build>/{<archive>, build-id.json, install/}`, one directory per
    # build, overwritten in place, the manifest authoritative. Under the
    # data root rather than the checkout, so one host serves several
    # checkouts of a project. Keyed by the project's dev.yml `name`.
    #
    # The store reads only the builds the project declares. A directory
    # without a manifest is not an artifact; a directory for a build no
    # target declares is an orphan `dev cache gc` reclaims; a directory
    # whose manifest names another build is corrupt and an error.
    #
    # Beside the builds, `.<channel>/` is a publisher's scratch, where a
    # channel unpacks or wraps the read-only archives; the store hands out
    # the path and reads nothing in it. `.releases/<tag>/` is where `deploy
    # --release` keeps a release's `release.json` and verified archives, so
    # a second channel shipping the same release reads them from here. No
    # channel may be named `releases`.
    class Store
      extend T::Sig

      ARTIFACTS_DIR = "artifacts"
      INSTALL_DIR = "install"
      SCRATCH_PREFIX = "."
      RELEASES_DIR = "releases"

      # An artifact directory whose `build-id.json` is of a different build
      # than the directory is named for.
      class MisnamedArtifactError < RuntimeError; end

      # @return [Pathname] this project's root in the store
      sig { returns(Pathname) }
      attr_reader :root

      # @param project_name [String] dev.yml `name`
      # @param targets [Array<Target>] the project's declared targets
      # @param data_root [String] (tests use a tmpdir)
      sig { params(project_name: String, targets: T::Array[Target], data_root: String).void }
      def initialize(project_name:, targets:, data_root: Dev::DataRoot.path)
        @targets = targets
        @root = T.let(Pathname(data_root) / ARTIFACTS_DIR / project_name, Pathname)
      end

      # Where a build's artifact is — or would be.
      #
      # @param build [Build]
      # @return [Pathname]
      sig { params(build: Build).returns(Pathname) }
      def dir(build)
        @root / build.name
      end

      # Where a build's install goes: the directory the builder writes
      # (`DEV_INSTALL`) and the packager reads, inside the artifact
      # directory so one build's state is reclaimed as one.
      #
      # @param build [Build]
      # @return [Pathname]
      sig { params(build: Build).returns(Pathname) }
      def install_dir(build)
        dir(build) / INSTALL_DIR
      end

      # The archive's path without its extension — what the packager is
      # handed (`DEV_ARTIFACT`) and appends its format's extension to.
      #
      # @param build [Build]
      # @return [Pathname]
      sig { params(build: Build).returns(Pathname) }
      def archive_stem(build)
        dir(build) / build.name
      end

      # A channel's scratch directory — handed to its publisher at deploy,
      # which creates it when it needs it.
      #
      # @param channel [Channel]
      # @return [Pathname]
      sig { params(channel: Channel).returns(Pathname) }
      def scratch(channel)
        @root / "#{SCRATCH_PREFIX}#{channel.name}"
      end

      # Where a release's downloaded archives and `release.json` are kept
      # for `deploy --release` — or would be.
      #
      # @param tag [ReleaseTag]
      # @return [Pathname]
      sig { params(tag: ReleaseTag).returns(Pathname) }
      def release_dir(tag)
        @root / "#{SCRATCH_PREFIX}#{RELEASES_DIR}" / tag.name
      end

      # The stamped artifact of a build, or nil when none has been packaged
      # (or one was started and never stamped).
      #
      # @param build [Build]
      # @return [Artifact, nil]
      # @raise [MisnamedArtifactError]
      # @raise [Manifest::MalformedManifestError]
      sig { params(build: Build).returns(T.nilable(Artifact)) }
      def artifact(build)
        directory = dir(build)
        return nil unless (directory / Manifest::Artifact::FILE_NAME).file?

        manifest = Manifest::Artifact.read(directory, targets: @targets)
        unless manifest.build == build
          raise MisnamedArtifactError,
            "#{directory} is named for #{build} but its #{Manifest::Artifact::FILE_NAME} says #{manifest.build}; " \
              "remove the directory and package again"
        end

        Artifact.new(dir: directory, manifest:)
      end

      # Every stamped artifact of a declared build, in target declaration
      # order.
      #
      # @return [Array<Artifact>]
      # @raise [MisnamedArtifactError]
      # @raise [Manifest::MalformedManifestError]
      sig { returns(T::Array[Artifact]) }
      def artifacts
        @targets.flat_map(&:builds).filter_map { |build| artifact(build) }
      end

      # Stamp a build's directory with its manifest — the last step of
      # `package`, after the archive is in place, so a directory without one
      # reads as unpackaged.
      #
      # @param manifest [Manifest::Artifact]
      # @return [Artifact] the stamped artifact
      sig { params(manifest: Manifest::Artifact).returns(Artifact) }
      def stamp(manifest)
        directory = dir(manifest.build)
        directory.mkpath
        manifest.write(directory)
        Artifact.new(dir: directory, manifest:)
      end
    end
  end
end
