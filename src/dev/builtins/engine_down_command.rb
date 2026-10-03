# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/command"
require "dev/confirmer"
require "dev/container_engine"
require "dev/engine_provisioner"

module Dev
  module Builtins
    # `dev engine down` — power the engine off; the engine itself is the
    # target, so whatever runs in it has to go first. dev's own build
    # containers (any checkout) are stopped without asking: `stop -t 0`
    # keeps their writable layer, exactly what `dev container down` there
    # would do. Containers dev does not manage are the user's: they are
    # listed and the user is asked, `--force` answering yes up front (a
    # script's consent). A no leaves the engine running and is a refusal.
    #
    # Contrast `dev down`, which brings this checkout down and stops the
    # engine only if that left it idle.
    class EngineDownCommand < BuiltinCommand
      extend T::Sig

      # The user declined to stop containers dev does not manage, so the
      # engine stays up.
      class EngineBusyError < RuntimeError; end

      # Stopping a container through the engine failed.
      class StopFailedError < RuntimeError; end

      FORCE_FLAG = "--force"

      # @param provisioner [Dev::EngineProvisioner] owns the engine and its stop
      # @param confirmer [Dev::Confirmer] asks about the user's own containers
      # @param out [IO, StringIO]
      # @param home [String] abbreviated as `~` when naming checkouts
      sig do
        params(
          provisioner: Dev::EngineProvisioner,
          confirmer: Dev::Confirmer,
          out: T.any(IO, StringIO),
          home: String,
        ).void
      end
      def initialize(provisioner: Dev::EngineProvisioner.new, confirmer: Dev::Confirmer.new, out: $stdout,
        home: Dir.home)
        super()
        @provisioner = provisioner
        @confirmer = confirmer
        @out = out
        @home = home
      end

      sig { override.returns(String) }
      def desc = "Stop the container engine, stopping dev's build containers first (--force: the rest too)"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Lifecycle

      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      # @param args [Array<String>] `--force` stops unmanaged containers unasked
      # @param context [ExecutionContext] unused: the engine is machine state
      # @return [void]
      # @raise [Dev::EngineProvisioner::UnmanagedEngineError] on an engine dev did not provision
      # @raise [EngineBusyError] when the user declines to stop their own containers
      # @raise [StopFailedError] when a container will not stop
      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        @provisioner.assert_stoppable!
        engine = @provisioner.engine
        managed, foreign = engine.running_containers.partition(&:managed)

        managed.each do |container|
          stop(engine, container)
          @out.puts "dev: stopped build container: #{container.describe(home: @home)}"
        end

        unless foreign.empty?
          @out.puts "dev: containers running that dev does not manage:"
          foreign.each { |container| @out.puts "  #{container.describe(home: @home)}" }
          unless args.include?(FORCE_FLAG) || @confirmer.confirm?("dev: stop them too?")
            raise EngineBusyError,
              "engine left running — not stopping #{foreign.map(&:name).join(", ")} (pass #{FORCE_FLAG} to)."
          end
          foreign.each { |container| stop(engine, container) }
        end

        @provisioner.stop!
        @out.puts "dev: engine stopped."
      end

      private

      # `stop -t 0`: PID 1 is `sleep infinity` in dev's containers, which
      # ignores SIGTERM, and the user's are being stopped on purpose anyway.
      #
      # @param engine [Dev::ContainerEngine]
      # @param container [Dev::ContainerEngine::RunningContainer]
      # @return [void]
      # @raise [StopFailedError]
      sig { params(engine: Dev::ContainerEngine, container: Dev::ContainerEngine::RunningContainer).void }
      def stop(engine, container)
        return if engine.run(["stop", "-t", "0", container.name], out: File::NULL, err: File::NULL)

        raise StopFailedError, "could not stop container #{container.name}."
      end
    end
  end
end
