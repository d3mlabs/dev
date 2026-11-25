# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "acceptance"
require_relative "build"
require_relative "packager"
require_relative "packed_archive"
require_relative "script_env"
require_relative "script_source"
require_relative "shell"

module Dev
  module Lifecycle
    # The script form of the Packager port: the target's `packager:` script,
    # run at the project root with the build, the stage and `DEV_ARTIFACT`
    # (the archive path without its extension) in its env. The script
    # appends the extension of whatever it writes. What it wrote is read
    # back as the `<archive>.*` files that were not there before: the
    # lexically first is the archive the manifest records, the rest its
    # parts, which is the order dev's own split form sorts in.
    class ScriptPackager
      extend T::Sig
      include Packager

      # The script ended other than with exit 0.
      class PackageScriptFailedError < RuntimeError; end

      # The script exited 0 and wrote no `<archive>.*` file.
      class NothingPackagedError < RuntimeError; end

      # @return [String] the `packager:` command line as declared
      sig { returns(String) }
      attr_reader :command

      # @param command [String] the target's `packager:` script, a shell command
      # @param project_root [Pathname] where the script runs
      # @param shell [Shell]
      sig { params(command: String, project_root: Pathname, shell: Shell).void }
      def initialize(command:, project_root:, shell: Shell.new)
        @command = command
        @project_root = project_root
        @shell = shell
        @source = T.let(ScriptSource.new(command:, project_root:), ScriptSource)
      end

      # @param build [Build]
      # @param stage [Pathname] the stage the builder wrote
      # @param archive [Pathname] the path without extension; its directory
      #   is created if absent
      # @param acceptance [Acceptance] unused: what the script archives is
      #   the script's, so dev has no tree to present
      # @return [PackedArchive]
      # @raise [PackageScriptFailedError]
      # @raise [NothingPackagedError]
      # @raise [Shell::SpawnError]
      sig { override.params(build: Build, stage: Pathname, archive: Pathname, acceptance: Acceptance).returns(PackedArchive) }
      def package(build, stage, archive, acceptance: Acceptance.unconditional)
        _ = acceptance
        archive.dirname.mkpath
        before = written(archive)
        env = ScriptEnv.for_package(build, stage:, archive:)
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

      # The one-release alias of `DEV_STAGE`, when the script reads it.
      sig { override.returns(T::Array[String]) }
      def deprecations
        return [] unless @source.mentions?(ScriptEnv::STAGE_ALIAS)

        [ScriptEnv.stage_alias_deprecation(script: "packager:")]
      end

      # The declaration as `dev help` renders it: the line itself.
      sig { returns(String) }
      def to_s
        @command
      end

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
