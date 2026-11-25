# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "build"
require_relative "builder"
require_relative "script_env"
require_relative "script_source"
require_relative "shell"

module Dev
  module Lifecycle
    # The script form of the Builder port: the target's `builder:` script, run
    # at the project root with the build in its env and `DEV_STAGE` naming
    # the directory to stage into. The script owns the mapping from dev's
    # ids to the toolchain's switches; dev owns where the stage goes and
    # what a failure means. Spawn-and-wait: the stage has work after the
    # builder returns.
    #
    # The project root and the shell are fixed for a checkout and so are
    # constructor-owned; the build is per call.
    class ScriptBuilder
      extend T::Sig
      include Builder

      # The script ended other than with exit 0 — including a declared
      # build name it refused (`*) exit 2`).
      class BuildScriptFailedError < RuntimeError; end

      # @return [String] the `builder:` command line as declared
      sig { returns(String) }
      attr_reader :command

      # @param command [String] the target's `builder:` script, a shell command
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
      # @param stage [Pathname] the fresh stage, handed to the script as
      #   `DEV_STAGE`
      # @return [void]
      # @raise [BuildScriptFailedError]
      # @raise [Shell::SpawnError]
      sig { override.params(build: Build, stage: Pathname).void }
      def fill(build, stage)
        status = @shell.run(["sh", "-c", @command], chdir: @project_root, env: ScriptEnv.for_build(build, stage:))
        return if status.success?

        raise BuildScriptFailedError, "build script `#{@command}` for #{build} #{Shell.describe(status)}"
      end

      # A script takes its parameters from the env, never from the target.
      sig { override.returns(T::Array[String]) }
      def target_options_schema
        []
      end

      # What the manifest records for a stage a `builder:` script made.
      NAME = "script"

      sig { override.returns(String) }
      def name
        NAME
      end

      # A script has no version of its own: the tree it ran in is the
      # provenance, and the manifest's sha records that.
      sig { override.returns(T.nilable(String)) }
      def version
        nil
      end

      # The one-release alias of `DEV_STAGE`, when the script reads it.
      sig { override.returns(T::Array[String]) }
      def deprecations
        return [] unless @source.mentions?(ScriptEnv::STAGE_ALIAS)

        [ScriptEnv.stage_alias_deprecation(script: "builder:")]
      end

      # The declaration as `dev help` renders it: the line itself.
      sig { returns(String) }
      def to_s
        @command
      end
    end
  end
end
