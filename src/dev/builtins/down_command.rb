# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/command"
require "dev/builtins/service_down"
require "dev/engine_provisioner"

module Dev
  module Builtins
    # `dev down` — the intent behind `dev up`, reversed, for this checkout:
    # its service dependencies come down (the build container stops, warm),
    # and the engine stops too when nothing else is using it. It never
    # reaches further than that — another checkout's container, or one dev
    # does not manage, leaves the engine running and is named so you know
    # why; `dev engine down` is the verb that stops those. Exists only where
    # the project has a service dependency to bring down.
    class DownCommand < BuiltinCommand
      extend T::Sig

      # @param service_dependencies [Array<ServiceDown>] the same list `dev up`
      #   brings up (see UpCommand), through its bring-down port; walked in
      #   reverse bring-up order, before the engine is considered
      # @param provisioner [Dev::EngineProvisioner] owns the engine and its stop
      # @param out [IO, StringIO]
      # @param home [String] abbreviated as `~` when naming checkouts
      sig do
        params(
          service_dependencies: T::Array[ServiceDown],
          provisioner: Dev::EngineProvisioner,
          out: T.any(IO, StringIO),
          home: String,
        ).void
      end
      def initialize(service_dependencies: [], provisioner: Dev::EngineProvisioner.new, out: $stdout, home: Dir.home)
        super()
        @service_dependencies = service_dependencies
        @provisioner = provisioner
        @out = out
        @home = home
      end

      sig { override.returns(String) }
      def desc = "Stop this checkout's service dependencies, and the engine if nothing else uses it"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Lifecycle

      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      # @param args [Array<String>] unused
      # @param context [ExecutionContext] the project
      # @return [void]
      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        project = context.project!
        @service_dependencies.reverse_each { |service| service.down(project:) }

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
