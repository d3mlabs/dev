# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "artifact"
require_relative "channel"
require_relative "publisher"
require_relative "script_env"
require_relative "shell"
require_relative "track"

module Dev
  module Lifecycle
    # The script form of the Publisher port (dev#192, K5): the channel's
    # `run:` line, run at the project root **once per selected archive**
    # with the archive and its manifest in its env (ScriptEnv.for_deploy).
    # The script owns the protocol — unzip and rsync, scp, an upload API —
    # and resolves its own credentials (`dev cred get deploy.staging host`
    # as its first line); dev owns which archives reach it and what a
    # failure means. The archives are the script's read-only input — what
    # it unpacks or wraps goes in the channel's scratch (`DEV_SCRATCH`),
    # created before the first run so the script can use it as it is; the
    # first failing run ends the deploy, the archives before it shipped.
    # Spawn-and-wait, as every lifecycle seam is: the stage has work after
    # the protocol returns.
    #
    # The project root and the shell are fixed for a checkout and so are
    # constructor-owned; the artifacts are per call.
    class ScriptPublisher
      extend T::Sig
      include Publisher

      # The script ended other than with exit 0 for one of the archives.
      class DeployScriptFailedError < RuntimeError; end

      # @return [String] the `run:` line as declared
      sig { returns(String) }
      attr_reader :command

      # @param command [String] the channel's `run:` line, a shell command
      # @param project_root [Pathname] where the script runs
      # @param shell [Shell]
      sig { params(command: String, project_root: Pathname, shell: Shell).void }
      def initialize(command:, project_root:, shell: Shell.new)
        @command = command
        @project_root = project_root
        @shell = shell
      end

      # @param artifacts [Array<Artifact>] shipped in this order, one run each
      # @param channel [Channel]
      # @param track [Track] what `DEV_TRACK` carries
      # @param scratch [Pathname] what `DEV_SCRATCH` carries; created here
      # @return [void]
      # @raise [DeployScriptFailedError] at the first archive the script fails on
      # @raise [Shell::SpawnError]
      sig { override.params(artifacts: T::Array[Artifact], channel: Channel, track: Track, scratch: Pathname).void }
      def publish(artifacts, channel:, track:, scratch:)
        scratch.mkpath
        artifacts.each do |artifact|
          env = ScriptEnv.for_deploy(artifact, channel: channel.name, track:, scratch:)
          status = @shell.run(["sh", "-c", @command], chdir: @project_root, env:)
          next if status.success?

          raise DeployScriptFailedError,
            "deploy script `#{@command}` for #{artifact.name} → #{channel} #{Shell.describe(status)}"
        end
      end

      # The declaration as `dev help` renders it: the line itself.
      sig { returns(String) }
      def to_s = @command
    end
  end
end
