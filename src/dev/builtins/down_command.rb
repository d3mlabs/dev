# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/command"
require "dev/builtins/container_down_command"
require "dev/engine_provisioner"

module Dev
  module Builtins
    # `dev down` — the intent behind `dev up`, reversed, for this checkout:
    # its build container stops (warm), and the engine stops too when
    # nothing else is using it. It never reaches further than that — another
    # checkout's container, or one dev does not manage, leaves the engine
    # running and is named so you know why; `dev engine down` is the verb
    # that stops those. Exists only where `dev up` has a container to bring
    # up (the project declares `build.container`).
    class DownCommand < BuiltinCommand
      extend T::Sig

      # @param container_down_command [ContainerDownCommand] the `dev container down` body
      # @param provisioner [Dev::EngineProvisioner] owns the engine and its stop
      # @param out [IO, StringIO]
      # @param home [String] abbreviated as `~` when naming checkouts
      sig do
        params(
          container_down_command: ContainerDownCommand,
          provisioner: Dev::EngineProvisioner,
          out: T.any(IO, StringIO),
          home: String,
        ).void
      end
      def initialize(container_down_command: ContainerDownCommand.new, provisioner: Dev::EngineProvisioner.new,
        out: $stdout, home: Dir.home)
        super()
        @container_down_command = container_down_command
        @provisioner = provisioner
        @out = out
        @home = home
      end

      sig { override.returns(String) }
      def desc = "Stop this checkout's build container, and the engine if nothing else uses it"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Lifecycle

      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      # @param args [Array<String>] unused
      # @param context [ExecutionContext] the project
      # @return [void]
      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        @container_down_command.call(args: [], context:)

        unless @provisioner.stoppable?
          @out.puts "dev: engine left running (not managed by dev)."
          return
        end

        running = @provisioner.engine.running_containers
        if running.empty?
          @provisioner.stop!
          @out.puts "dev: engine stopped."
        else
          @out.puts "dev: engine left running — still in use by:"
          running.each { |container| @out.puts "  #{container.describe(home: @home)}" }
        end
      end
    end
  end
end
