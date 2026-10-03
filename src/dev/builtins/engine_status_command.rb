# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/command"
require "dev/engine_provisioner"
require "dev/engine_resources"

module Dev
  module Builtins
    # `dev engine status` — what the engine is, whether it is up and dev's to
    # stop, its size, the per-kind converge facts (colima VM; dockerd and,
    # on WSL2, the `.wslconfig` configured-vs-observed gap that says a
    # restart is pending), and what runs in it. A pure report: nothing is
    # started or stopped.
    class EngineStatusCommand < BuiltinCommand
      extend T::Sig

      # @param provisioner [Dev::EngineProvisioner] gathers the facts
      # @param out [IO, StringIO]
      # @param home [String] abbreviated as `~` when naming checkouts
      sig { params(provisioner: Dev::EngineProvisioner, out: T.any(IO, StringIO), home: String).void }
      def initialize(provisioner: Dev::EngineProvisioner.new, out: $stdout, home: Dir.home)
        super()
        @provisioner = provisioner
        @out = out
        @home = home
      end

      sig { override.returns(String) }
      def desc = "Report the container engine: kind, state, size, converge facts, running containers"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Lifecycle

      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      # @param args [Array<String>] unused
      # @param context [ExecutionContext] unused: the engine is machine state
      # @return [void]
      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        status = @provisioner.status
        @out.puts "engine: #{engine_line(status)}"
        linux = status.linux
        @out.puts "dockerd: #{dockerd_line(linux)}" if linux
        wsl = status.wsl
        @out.puts "wsl: #{wsl_line(wsl)}" if wsl
        if status.containers.empty?
          @out.puts "containers running: none"
        else
          @out.puts "containers running:"
          status.containers.each { |container| @out.puts "  #{container.describe(home: @home)}" }
        end
      end

      private

      # @param status [Dev::EngineProvisioner::EngineStatus]
      # @return [String] e.g. "colima VM — running, 8 cpus / 16 GiB"
      sig { params(status: Dev::EngineProvisioner::EngineStatus).returns(String) }
      def engine_line(status)
        name =
          case status.kind
          when :colima then "colima VM"
          when :explicit then "DOCKER_HOST (yours, not managed by dev)"
          else status.stoppable ? "dockerd" : "dockerd (Docker Desktop, not managed by dev)"
          end
        return "#{name} — not created (dev engine up creates it)" if status.kind == :colima && status.colima.nil?
        return "#{name} — not reachable" if status.kind == :explicit && !status.running

        state = status.running ? "running" : "stopped"
        size = status.resources
        size ? "#{name} — #{state}, #{size}" : "#{name} — #{state}"
      end

      # @param linux [Dev::LinuxEngineProvisioner::Status]
      # @return [String] converged, or every fact that is not
      sig { params(linux: Dev::LinuxEngineProvisioner::Status).returns(String) }
      def dockerd_line(linux)
        return "converged (docker group, buildx)" if linux.converged?

        gaps = []
        gaps << "docker not installed" if linux.docker_path.nil?
        gaps << "Docker Desktop shim owns docker" if linux.desktop_shim
        gaps << "not in the docker group" unless linux.in_docker_group
        gaps << "no buildx" unless linux.buildx
        gaps << "systemd off in wsl.conf" if linux.systemd_enabled == false
        "not converged — #{gaps.join(", ")} (dev engine up fixes this)"
      end

      # @param wsl [Dev::WslHost::Status]
      # @return [String] configured vs observed, restart pending, hardware cap
      sig { params(wsl: Dev::WslHost::Status).returns(String) }
      def wsl_line(wsl)
        observed = "VM running at #{wsl.observed}"
        return "#{observed}; .wslconfig unreadable (Windows interop is off)" unless wsl.interop

        configured =
          if wsl.configured_cpus.nil? && wsl.configured_memory_gib.nil?
            ".wslconfig has no sizing (WSL defaults)"
          else
            ".wslconfig #{wsl.configured_cpus || "?"} cpus / #{wsl.configured_memory_gib || "?"} GiB"
          end
        pending = wsl.restart_pending? ? " — restart pending (wsl --shutdown from Windows)" : ""
        "#{configured}, #{observed}#{pending}; hardware #{wsl.hardware}"
      end
    end
  end
end
