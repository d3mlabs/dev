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
    # The env contract of the script forms (dev#192, K1): what a target's
    # `build:` and `package:` lines read instead of flags. The build's
    # axes arrive as `DEV_TARGET`, `DEV_PLATFORM` and `DEV_CONFIG` — each
    # axis set exactly when the target declares it, so a script's `case`
    # over an undeclared axis fails loudly under `set -u` rather than
    # matching an empty string — then `DEV_INSTALL` (the install directory
    # the builder writes and the packager reads) and, for `package:`,
    # `DEV_ARTIFACT` (the archive path without its extension). The mapping
    # from dev's ids to the toolchain's switches is the script's `case`,
    # and a declared name it does not handle must fail (`*) exit 2`).
    #
    # A channel's `run:` reads the same axes for the archive it ships,
    # with `DEV_ARTIFACT` now the archive file itself (a split set's
    # `MANIFEST`; the parts sit beside it), `DEV_CHANNEL`, `DEV_TRACK` (the
    # track the source decided: `testing` from the store, `live` for a
    # release's archives), `DEV_SCRATCH` (the channel's own directory in
    # the store, for whatever the script unpacks or wraps — the archive
    # itself is read-only), `DEV_BUILD`, `DEV_BUILD_ID`,
    # `DEV_ARCHIVE_SHA256`, and what the source says of it (dev#192, K5;
    # dev#425): a **store** artifact brings its manifest's `DEV_SHA`,
    # `DEV_DIRTY` and `DEV_PACKAGED_AT`, so the script can name what it
    # shipped and refuse a dirty one without reading `build-id.json`; a
    # **release**'s archive brings `DEV_RELEASE_VERSION` (the version as
    # given to `--release`) and `DEV_SHA` (the tag's commit, as
    # `release.json` records it) — and nothing of a working tree, since a
    # release is cut from a clean one. Each key is set exactly when it
    # applies, so a script's `${DEV_RELEASE_VERSION}` under `set -u`
    # fails loudly on a testing deploy rather than reading an empty
    # version.
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
