# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "build"
require_relative "git_state"
require_relative "manifest"
require_relative "shipment"
require_relative "track"

module Dev
  module Lifecycle
    # The env the script forms read instead of flags. A `build:` or
    # `package:` script gets the build's axes as `DEV_TARGET`,
    # `DEV_PLATFORM` and `DEV_CONFIG` (each set exactly when the target
    # declares it, so a `case` over an undeclared axis fails under `set
    # -u`), `DEV_INSTALL`, and for `package:` `DEV_ARTIFACT` (the archive
    # path without its extension).
    #
    # A channel's `run:` gets the same axes for the archive it ships,
    # `DEV_ARTIFACT` as the archive file itself, `DEV_CHANNEL`, `DEV_TRACK`,
    # `DEV_SCRATCH`, `DEV_BUILD`, `DEV_BUILD_ID`, `DEV_ARCHIVE_SHA256`, and
    # the provenance's keys: `DEV_SHA`, `DEV_DIRTY` and `DEV_PACKAGED_AT`
    # for a store artifact, `DEV_RELEASE_VERSION` and `DEV_SHA` for a
    # release's archive. Each key is set exactly when it applies.
    module ScriptEnv
      TARGET = "DEV_TARGET"
      PLATFORM = "DEV_PLATFORM"
      CONFIG = "DEV_CONFIG"
      INSTALL = "DEV_INSTALL"
      ARTIFACT = "DEV_ARTIFACT"
      CHANNEL = "DEV_CHANNEL"
      TRACK = "DEV_TRACK"
      SCRATCH = "DEV_SCRATCH"
      BUILD = "DEV_BUILD"
      BUILD_ID = "DEV_BUILD_ID"
      SHA = "DEV_SHA"
      DIRTY = "DEV_DIRTY"
      PACKAGED_AT = "DEV_PACKAGED_AT"
      ARCHIVE_SHA256 = "DEV_ARCHIVE_SHA256"
      RELEASE_VERSION = "DEV_RELEASE_VERSION"

      # What `DEV_SHA` carries for an artifact packaged outside a checkout.
      UNKNOWN_SHA = "unknown"

      Env = T.type_alias { T::Hash[String, String] }

      class << self
        extend T::Sig

        # The env a `build:` script runs with.
        #
        # @param build [Build]
        # @param install [Pathname] the directory to write the install into
        # @return [Hash{String => String}]
        sig { params(build: Build, install: Pathname).returns(Env) }
        def for_build(build, install:)
          axes(build).merge(INSTALL => install.to_s)
        end

        # The env a `package:` script runs with.
        #
        # @param build [Build]
        # @param install [Pathname] the install the builder wrote
        # @param archive [Pathname] the archive path without its extension
        # @return [Hash{String => String}]
        sig { params(build: Build, install: Pathname, archive: Pathname).returns(Env) }
        def for_package(build, install:, archive:)
          for_build(build, install:).merge(ARTIFACT => archive.to_s)
        end

        # The env a channel's `run:` ships one archive with.
        #
        # @param shipment [Shipment] the one being shipped
        # @param channel [String] the channel's name
        # @param track [Track] the track the source decided
        # @param scratch [Pathname] the channel's scratch directory
        # @return [Hash{String => String}]
        sig { params(shipment: Shipment, channel: String, track: Track, scratch: Pathname).returns(Env) }
        def for_deploy(shipment, channel:, track:, scratch:)
          axes(shipment.build).merge(
            ARTIFACT => shipment.archive.to_s,
            CHANNEL => channel,
            TRACK => track.to_s,
            SCRATCH => scratch.to_s,
            BUILD => shipment.name,
            BUILD_ID => shipment.build_id.to_s,
            ARCHIVE_SHA256 => shipment.archive_sha256,
          ).merge(provenance(shipment.provenance))
        end

        private

        # What the source says of the archive: the manifest's keys for a
        # store artifact, the release's version and commit for a release's.
        #
        # @param provenance [Provenance]
        # @return [Hash{String => String}]
        sig { params(provenance: Provenance).returns(Env) }
        def provenance(provenance)
          case provenance
          when Provenance::Store
            {
              SHA => provenance.state.sha || UNKNOWN_SHA,
              DIRTY => provenance.state.dirty.to_s,
              PACKAGED_AT => provenance.packaged_at.strftime(Manifest::INSTANT_FORMAT),
            }
          when Provenance::Release
            # The short form, as a store artifact's `DEV_SHA` and every build
            # id spell a commit; `release.json` records the full one.
            { RELEASE_VERSION => provenance.tag.version, SHA => T.must(provenance.sha[0, GitState::SHORT_SHA_LENGTH]) }
          else
            # simplecov:disable — the sealed provenance has no third variant;
            # T.absurd keeps the static proof.
            T.absurd(provenance)
            # simplecov:enable
          end
        end

        # @param build [Build]
        # @return [Hash{String => String}] the declared axes only
        sig { params(build: Build).returns(Env) }
        def axes(build)
          platform = build.platform
          config = build.config
          env = { TARGET => build.target.name }
          env[PLATFORM] = platform.to_s if platform
          env[CONFIG] = config.to_s if config
          env
        end
      end
    end
  end
end
