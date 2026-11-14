# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "channel"
require_relative "publisher"
require_relative "receipt"
require_relative "script_env"
require_relative "shell"
require_relative "shipment"
require_relative "track"

module Dev
  module Lifecycle
    # The script form of the Publisher port: the channel's `run:` line, run
    # at the project root once per selected archive with the archive and
    # its provenance in its env. The script owns the protocol and resolves
    # its own credentials; dev owns which archives reach it and what a
    # failure means. The archives are read-only input; what the script
    # unpacks or wraps goes in `DEV_SCRATCH`. The first failing run ends the
    # deploy, the archives before it shipped. A script has no way to say
    # what landed, so its receipt is the line that shipped.
    #
    # The project root and the shell are fixed for a checkout and so are
    # constructor-owned; the shipments are per call.
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

      # @param shipments [Array<Shipment>] shipped in this order, one run each
      # @param channel [Channel]
      # @param track [Track] what `DEV_TRACK` carries
      # @param scratch [Pathname] what `DEV_SCRATCH` carries; created here
      # @return [Receipt] the `run:` line, as `dev help` renders it
      # @raise [DeployScriptFailedError] at the first archive the script fails on
      # @raise [Shell::SpawnError]
      sig { override.params(shipments: T::Array[Shipment], channel: Channel, track: Track, scratch: Pathname).returns(Receipt) }
      def publish(shipments, channel:, track:, scratch:)
        scratch.mkpath
        shipments.each do |shipment|
          env = ScriptEnv.for_deploy(shipment, channel: channel.name, track:, scratch:)
          status = @shell.run(["sh", "-c", @command], chdir: @project_root, env:)
          next if status.success?

          raise DeployScriptFailedError,
            "deploy script `#{@command}` for #{shipment.name} → #{channel} #{Shell.describe(status)}"
        end
        Receipt.new(summary: "run: #{@command}")
      end

      # The declaration as `dev help` renders it: the line itself.
      sig { returns(String) }
      def to_s
        @command
      end
    end
  end
end
