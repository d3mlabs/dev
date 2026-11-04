# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "packed_archive"
# Build appears in signatures only, which are resolved lazily; requiring
# build.rb here would close a load cycle (Build → Target → PackagerSpec →
# Archive → this port). `dev/lifecycle` loads both.

module Dev
  module Lifecycle
    # The port between dev and the archive format for the `package` verb
    # (dev#192, K1): turn a build's install into its **archive** — the one
    # file (or split set) a release attaches and a channel uploads,
    # byte-identical whichever channel takes it. The packager never knows
    # the toolchain; dev's own `archive` (Archive) is the default and
    # needs no declaration.
    #
    # Built-ins: Archive (`archive` — a zip, or the split `tar.zst` form),
    # AsIsPackager (`as-is` — an install that already is an archive:
    # Alpakit's zip, `gem build`'s `.gem`), NonePackager (`none` — built,
    # never shipped). The script form is ScriptPackager (the target's
    # `package:` line); an integration form lands with dev#433.
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
