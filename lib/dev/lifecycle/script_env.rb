# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "build"

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
    module ScriptEnv
      TARGET = "DEV_TARGET"
      PLATFORM = "DEV_PLATFORM"
      CONFIG = "DEV_CONFIG"
      INSTALL = "DEV_INSTALL"
      ARTIFACT = "DEV_ARTIFACT"

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
