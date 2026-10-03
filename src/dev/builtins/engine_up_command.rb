# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/command"
require "dev/engine_provisioner"

module Dev
  module Builtins
    # `dev engine up` — bring the container engine up for the invoking user:
    # start (and size) the colima VM, converge dockerd on Linux/WSL, ratchet
    # `.wslconfig`. Global: the engine is machine state, not project state.
    # Inside a containerized project the repo's resources hint sizes it;
    # anywhere else the engine's own defaults apply. The same step
    # `container up` (and so `dev up`) performs first.
    class EngineUpCommand < BuiltinCommand
      extend T::Sig

      # @param provisioner [Dev::EngineProvisioner] the per-kind engine steps
      # @param out [IO, StringIO]
      sig { params(provisioner: Dev::EngineProvisioner, out: T.any(IO, StringIO)).void }
      def initialize(provisioner: Dev::EngineProvisioner.new, out: $stdout)
        super()
        @provisioner = provisioner
        @out = out
      end

      sig { override.returns(String) }
      def desc = "Start the container engine (sized from this project's resources hint when inside one)"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Lifecycle

      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      # @param args [Array<String>] unused
      # @param context [ExecutionContext] the project, if any, supplies the hint
      # @return [void]
      # @raise [Dev::EngineProvisioner] see its provision! for the per-kind failures
      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        @provisioner.provision!(resources: context.project&.build_container&.resources)
        @out.puts "dev: engine up."
      end
    end
  end
end
