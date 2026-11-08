# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "artifact"
require_relative "build"
require_relative "build_id"
require_relative "git_state"
require_relative "manifest"
require_relative "release_tag"

module Dev
  module Lifecycle
    # Where an archive `deploy` ships came from (dev#192, K4, K5): the
    # **store** — a working artifact `package` stamped from a working
    # tree, which ships on the testing track — or a **release** — an asset
    # of the GitHub release at a tag, downloaded and verified against
    # `release.json`, which ships on the live track (dev#425). The
    # provenance is what differs between the two sources once the archive
    # is on disk: the **ref** the deploy is recorded against (the commit
    # the artifact was packaged from; the release's tag), what a script
    # channel is told of it (`DEV_SHA`/`DEV_DIRTY`/`DEV_PACKAGED_AT`;
    # `DEV_RELEASE_VERSION`), and what a publisher may do with it (a
    # formula points at a release asset, never at a file in a store).
    #
    # Sealed, so the script env and the publishers match the two
    # exhaustively; a third source is unrepresentable.
    module Provenance
      extend T::Sig
      extend T::Helpers
      include Kernel
      abstract!
      sealed!

      # What the deploy is recorded against on the forge: a commit or a
      # tag. Nil when there is nothing to record against (an artifact
      # packaged outside a checkout).
      sig { abstract.returns(T.nilable(String)) }
      def ref; end

      # Packaged by `package` from a working tree: the tree's state and
      # when the packager finished, as `build-id.json` recorded them.
      class Store < T::Struct
        extend T::Sig
        include Provenance

        const :state, GitState
        const :packaged_at, Time

        # The commit the artifact was packaged from.
        sig { override.returns(T.nilable(String)) }
        def ref = state.sha

        sig { params(other: Object).returns(T::Boolean) }
        def ==(other) = other.is_a?(Store) && state == other.state && packaged_at == other.packaged_at

        sig { params(other: Object).returns(T::Boolean) }
        def eql?(other) = self == other

        sig { returns(Integer) }
        def hash = [Store, state, packaged_at].hash
      end

      # Downloaded from the GitHub release of a tag: the tag, and the
      # commit it points at as `release.json` records it. A release is
      # cut from a clean tree, so there is no dirty flag to carry.
      class Release < T::Struct
        extend T::Sig
        include Provenance

        const :tag, ReleaseTag
        const :sha, String

        # The release's tag — what `dev deploy status --release` reads by.
        sig { override.returns(T.nilable(String)) }
        def ref = tag.name

        sig { params(other: Object).returns(T::Boolean) }
        def ==(other) = other.is_a?(Release) && tag == other.tag && sha == other.sha

        sig { params(other: Object).returns(T::Boolean) }
        def eql?(other) = self == other

        sig { returns(Integer) }
        def hash = [Release, tag, sha].hash
      end
    end

    # One archive as `deploy` hands it to a channel's publisher (dev#192,
    # K5): the file — read-only input, a split set's `MANIFEST` with the
    # parts beside it — the build it is of, the id it was packaged under,
    # its digest, and its Provenance. What the two sources `deploy` selects
    # from have in common once the bytes are on disk: a publisher ships a
    # shipment the same way whichever source it came from, and reads the
    # provenance only where the source matters (the track is decided
    # before it — by the verb, from the same fact).
    class Shipment < T::Struct
      extend T::Sig

      const :archive, Pathname
      const :build, Build
      const :build_id, BuildId
      const :archive_sha256, String
      const :provenance, Provenance

      class << self
        extend T::Sig

        # A working artifact from the store.
        #
        # @param artifact [Artifact]
        # @return [Shipment]
        sig { params(artifact: Artifact).returns(Shipment) }
        def of_artifact(artifact)
          manifest = artifact.manifest
          new(
            archive: artifact.archive,
            build: manifest.build,
            build_id: manifest.build_id,
            archive_sha256: manifest.archive_sha256,
            provenance: Provenance::Store.new(state: manifest.state, packaged_at: manifest.packaged_at),
          )
        end

        # One archive of a release, downloaded and verified.
        #
        # @param entry [Manifest::Release::Archive] the archive's `release.json` entry
        # @param archive [Pathname] where it was downloaded to
        # @param tag [ReleaseTag] the release
        # @param sha [String] the commit the release records for its tag
        # @return [Shipment]
        sig { params(entry: Manifest::Release::Archive, archive: Pathname, tag: ReleaseTag, sha: String).returns(Shipment) }
        def of_release(entry, archive:, tag:, sha:)
          new(
            archive:,
            build: entry.build,
            build_id: entry.build_id,
            archive_sha256: entry.sha256,
            provenance: Provenance::Release.new(tag:, sha:),
          )
        end
      end

      # @return [String] the build's fully-qualified name
      sig { returns(String) }
      def name = build.name

      # What the deploy is recorded against (Provenance#ref).
      #
      # @return [String, nil]
      sig { returns(T.nilable(String)) }
      def ref = provenance.ref

      sig { returns(String) }
      def to_s = "#{name} (#{build_id})"

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        other.is_a?(Shipment) && archive == other.archive && build == other.build && build_id == other.build_id &&
          archive_sha256 == other.archive_sha256 && provenance == other.provenance
      end

      sig { params(other: Object).returns(T::Boolean) }
      def eql?(other) = self == other

      sig { returns(Integer) }
      def hash = [Shipment, archive, build, build_id, archive_sha256, provenance].hash
    end
  end
end
