# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "artifact"
require_relative "build"
require_relative "manifest"

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
    # A channel's `run:` reads the same axes for the artifact it ships,
    # with `DEV_ARTIFACT` now the archive file itself (the first part of a
    # split set; the rest sit beside it), `DEV_CHANNEL`, and the manifest's
    # keys — `DEV_BUILD`, `DEV_BUILD_ID`, `DEV_SHA`, `DEV_DIRTY`,
    # `DEV_PACKAGED_AT`, `DEV_ARCHIVE_SHA256` — so the script can name
    # what it shipped without reading `build-id.json` (dev#192, K5).
    module ScriptEnv
      TARGET = "DEV_TARGET"
      PLATFORM = "DEV_PLATFORM"
      CONFIG = "DEV_CONFIG"
      INSTALL = "DEV_INSTALL"
      ARTIFACT = "DEV_ARTIFACT"
      CHANNEL = "DEV_CHANNEL"
      BUILD = "DEV_BUILD"
      BUILD_ID = "DEV_BUILD_ID"
      SHA = "DEV_SHA"
      DIRTY = "DEV_DIRTY"
      PACKAGED_AT = "DEV_PACKAGED_AT"
      ARCHIVE_SHA256 = "DEV_ARCHIVE_SHA256"

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

        # The env a channel's `run:` ships one artifact with.
        #
        # @param artifact [Artifact] the one being shipped
        # @param channel [String] the channel's name
        # @return [Hash{String => String}]
        sig { params(artifact: Artifact, channel: String).returns(Env) }
        def for_deploy(artifact, channel:)
          manifest = artifact.manifest
          axes(artifact.build).merge(
            ARTIFACT => artifact.archive.to_s,
            CHANNEL => channel,
            BUILD => artifact.name,
            BUILD_ID => manifest.build_id.to_s,
            SHA => manifest.state.sha || UNKNOWN_SHA,
            DIRTY => manifest.state.dirty.to_s,
            PACKAGED_AT => manifest.packaged_at.strftime(Manifest::INSTANT_FORMAT),
            ARCHIVE_SHA256 => manifest.archive_sha256,
          )
        end

        private

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
