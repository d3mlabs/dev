# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "artifact"
require_relative "build"
require_relative "build_id"
require_relative "git_state"
require_relative "manifest"
require_relative "release_tag"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # Where an archive `deploy` ships came from: the store (an artifact
    # `package` stamped from a working tree; ships on the testing track) or
    # a release (an asset of the GitHub release at a tag, verified against
    # `release.json`; ships on the live track). The provenance decides the
    # ref the deploy is recorded against, what a script channel is told
    # (`DEV_SHA`/`DEV_DIRTY`/`DEV_PACKAGED_AT` or `DEV_RELEASE_VERSION`),
    # and what a publisher may do with it.
    #
    # Sealed, so the script env and the publishers match the two
    # exhaustively.
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
        include Dev::ValueEquality::Derived

        const :state, GitState
        const :packaged_at, Time

        # The commit the artifact was packaged from.
        sig { override.returns(T.nilable(String)) }
        def ref
          state.sha
        end

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [state, packaged_at]
        end
      end

      # Downloaded from the GitHub release of a tag: the tag, and the
      # commit it points at as `release.json` records it. A release is
      # cut from a clean tree, so there is no dirty flag to carry.
      class Release < T::Struct
        extend T::Sig
        include Provenance
        include Dev::ValueEquality::Derived

        const :tag, ReleaseTag
        const :sha, String

        # The release's tag — what `dev deploy status --release` reads by.
        sig { override.returns(T.nilable(String)) }
        def ref
          tag.name
        end

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [tag, sha]
        end
      end
    end

    # One archive as `deploy` hands it to a channel's publisher: the file
    # (read-only; a split set's `MANIFEST` with the parts beside it), the
    # build it is of, the id it was packaged under, its digest, and its
    # Provenance. A publisher ships a shipment the same way whichever source
    # it came from, and reads the provenance only where the source matters.
    class Shipment < T::Struct
      extend T::Sig
      include Dev::ValueEquality::Derived

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
      def name
        build.name
      end

      # What the deploy is recorded against (Provenance#ref).
      #
      # @return [String, nil]
      sig { returns(T.nilable(String)) }
      def ref
        provenance.ref
      end

      sig { returns(String) }
      def to_s
        "#{name} (#{build_id})"
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [archive, build, build_id, archive_sha256, provenance]
      end
    end
  end
end
