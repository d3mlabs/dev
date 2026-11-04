# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "build"
require_relative "packager"
require_relative "packed_archive"
require_relative "script_env"
require_relative "shell"

module Dev
  module Lifecycle
    # The script form of the Packager port (dev#192, K1): the target's
    # `package:` line, run at the project root with the build, the install
    # and `DEV_ARTIFACT` — the archive path without its extension — in its
    # env (ScriptEnv). The script appends the extension of whatever it
    # writes (`"$DEV_ARTIFACT.zip"`; `dev pack "$DEV_INSTALL" --out
    # "$DEV_ARTIFACT"` for dev's own forms with a twist). What it wrote is
    # read back as the files named `<archive>.*` that were not there
    # before: the lexically first is the archive the manifest records, the
    # rest its parts — which is the order dev's own split form sorts in
    # (`<build>.MANIFEST`, then `<build>.tar.zst.00…`).
    class ScriptPackager
      extend T::Sig
      include Packager

      # The script ended other than with exit 0.
      class PackageScriptFailedError < RuntimeError; end

      # The script exited 0 and wrote no `<archive>.*` file.
      class NothingPackagedError < RuntimeError; end

      # @return [String] the `package:` line as declared
      sig { returns(String) }
      attr_reader :command

      # @param command [String] the target's `package:` line, a shell command
      # @param project_root [Pathname] where the script runs
      # @param shell [Shell]
      sig { params(command: String, project_root: Pathname, shell: Shell).void }
      def initialize(command:, project_root:, shell: Shell.new)
        @command = command
        @project_root = project_root
        @shell = shell
      end

      # @param build [Build]
      # @param install [Pathname]
      # @param archive [Pathname] the path without extension; its directory
      #   is created if absent
      # @return [PackedArchive]
      # @raise [PackageScriptFailedError]
      # @raise [NothingPackagedError]
      # @raise [Shell::SpawnError]
      sig { override.params(build: Build, install: Pathname, archive: Pathname).returns(PackedArchive) }
      def package(build, install, archive)
        archive.dirname.mkpath
        before = written(archive)
        env = ScriptEnv.for_package(build, install:, archive:)
        status = @shell.run(["sh", "-c", @command], chdir: @project_root, env:)
        unless status.success?
          raise PackageScriptFailedError, "package script `#{@command}` for #{build} #{Shell.describe(status)}"
        end

        files = written(archive) - before
        if files.empty?
          raise NothingPackagedError,
            "package script `#{@command}` for #{build} wrote nothing at #{ScriptEnv::ARTIFACT}=#{archive}.<ext>"
        end

        PackedArchive.new(archive: T.must(files.first), parts: T.must(files[1..]))
      end

      # The declaration as `dev help` renders it: the line itself.
      sig { returns(String) }
      def to_s = @command

      private

      # The files that spell `<archive>.<something>`, sorted.
      #
      # @param archive [Pathname]
      # @return [Array<Pathname>]
      sig { params(archive: Pathname).returns(T::Array[Pathname]) }
      def written(archive)
        Pathname.glob("#{archive}.*").select(&:file?).sort
      end
    end
  end
end
