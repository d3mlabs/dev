# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "packed_archive"
# Build appears in signatures only, which are resolved lazily; requiring
# build.rb here would close a load cycle (Build → Target → PackagerSpec →
# Archive → this port). `dev/lifecycle` loads both.

module Dev
  module Lifecycle
    # The port between dev and the archive format: turn a build's install
    # into its archive, the one file (or split set) a release attaches and a
    # channel uploads. The packager never knows the toolchain.
    #
    # Built-ins: Archive (`archive`, the default), AsIsPackager (`as-is`, an
    # install that already is an archive), NonePackager (`none`, built and
    # never shipped). ScriptPackager is the target's `package:` line.
    module Packager
      extend T::Sig
      extend T::Helpers
      interface!

      # Make the archive from the install.
      #
      # @param build [Build] the build the install is of — the script form
      #   hands it to the script as `DEV_TARGET`/`DEV_PLATFORM`/`DEV_CONFIG`;
      #   the built-ins have no use for it
      # @param install [Pathname] the install the Builder wrote
      # @param archive [Pathname] the archive's path **without its
      #   extension** — `<artifact dir>/<build>` — to which the packager
      #   appends its format's (`.zip`, `.tar.zst`, the adopted file's)
      # @return [PackedArchive] what was written
      sig { abstract.params(build: Build, install: Pathname, archive: Pathname).returns(PackedArchive) }
      def package(build, install, archive); end
    end
  end
end
