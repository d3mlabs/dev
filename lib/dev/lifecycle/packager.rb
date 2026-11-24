# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "acceptance"
require_relative "packed_archive"
# Build appears in signatures only, which are resolved lazily; requiring
# build.rb here would close a load cycle (Build → Target → PackagerSpec →
# Archive → this port). `dev/lifecycle` loads both.

module Dev
  module Lifecycle
    # The port between dev and the archive format: turn a build's stage
    # into its archive, the one file (or split set) a release attaches and a
    # channel uploads. The packager never knows the toolchain.
    #
    # Built-ins: Archive (`archive`, the default), AsIsPackager (`as-is`, a
    # stage that already is an archive), NonePackager (`none`, built and
    # never shipped). ScriptPackager is the target's `packager:` script.
    #
    # A packager that writes a tree presents it to the destinations
    # (Acceptance) once selected and before the archive is written, so a
    # tree a channel would refuse never becomes an asset. Archive is that
    # packager; `as-is` adopts a file and a script's archive is the
    # script's, so neither has a tree to present.
    module Packager
      extend T::Sig
      extend T::Helpers
      abstract!

      # Make the archive from the stage.
      #
      # @param build [Build] the build the stage is of — the script form
      #   hands it to the script as `DEV_TARGET`/`DEV_PLATFORM`/`DEV_CONFIG`;
      #   the built-ins have no use for it
      # @param stage [Pathname] the stage the Builder wrote
      # @param archive [Pathname] the archive's path **without its
      #   extension** — `<artifact dir>/<build>` — to which the packager
      #   appends its format's (`.zip`, `.tar.zst`, the adopted file's)
      # @param acceptance [Acceptance] the destinations the tree is
      #   presented to before it is written; unconditional by default
      # @return [PackedArchive] what was written
      sig { abstract.params(build: Build, stage: Pathname, archive: Pathname, acceptance: Acceptance).returns(PackedArchive) }
      def package(build, stage, archive, acceptance: Acceptance.unconditional); end

      # What the verb tells the operator after this packager ran: each line
      # names something the declaration relies on that the next release
      # drops, and what to change. Nothing, for most packagers.
      #
      # @return [Array<String>]
      sig { overridable.returns(T::Array[String]) }
      def deprecations
        []
      end
    end
  end
end
