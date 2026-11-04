# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "../data_root"
require_relative "artifact"
require_relative "build"
require_relative "manifest"
require_relative "target"

module Dev
  module Lifecycle
    # The artifact store of one project: `<data root>/artifacts/<project>/
    # <build>/{<archive>, build-id.json}` (dev#192, K9) — one directory per
    # build, overwritten in place, the manifest authoritative (lifted from
    # cellbound-3d's `Staging::Slots`). Under the data root, not the
    # checkout: a checkout clean wipes `dist/`, and one host serves several
    # checkouts of a project. Keyed by the project's dev.yml `name`, as every
    # per-project state in the store is.
    #
    # The store reads only the builds the project declares: a directory
    # without a manifest is not an artifact (a packaging that never
    # finished), and a directory for a build no target declares any more is
    # an orphan this store does not see (`dev cache gc` reclaims it). A
    # directory whose manifest names another build is corrupt and an error,
    # because the name is only an index and the manifest is the truth.
    class Store
      extend T::Sig

      ARTIFACTS_DIR = "artifacts"

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
      def dir(build) = @root / build.name

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
      def artifacts = @targets.flat_map(&:builds).filter_map { |build| artifact(build) }

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
