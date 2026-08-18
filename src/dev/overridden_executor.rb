# typed: strict
# frozen_string_literal: true

require_relative "builtin_executor"
require_relative "command"
require_relative "execution_context"
require_relative "project_executor"

module Dev
  # The virtual-dispatch strategy: the builtin body is the hardcoded
  # super(), then the project command owns the slot. Composes the other two
  # strategies — the builtin stage runs through BuiltinExecutor, the
  # project tail through ProjectExecutor.
  class OverriddenExecutor
    extend T::Sig

    # @param builtin_executor [BuiltinExecutor]
    # @param project_executor [ProjectExecutor]
    sig { params(builtin_executor: BuiltinExecutor, project_executor: ProjectExecutor).void }
    def initialize(builtin_executor:, project_executor:)
      @builtin_executor = T.let(builtin_executor, BuiltinExecutor)
      @project_executor = T.let(project_executor, ProjectExecutor)
    end

    # Run the builtin stage, then the project tail. The tail's message
    # derives from the slot's stamping trait (the dev#85 invariant): a
    # stamping slot must run spawn-and-wait so the caller can sequence the
    # installed stamp after execute — exec-replace would make it
    # unreachable. Non-stamping slots keep the exec tail-call.
    #
    # @param command [OverriddenCommand]
    # @param args [Array<String>] argv after the command name
    # @param context [ExecutionContext]
    # @return [void]
    # @raise [CommandRunner::CommandFailedError] when a waited project tail
    #   fails
    sig { params(command: OverriddenCommand, args: T::Array[String], context: ExecutionContext).void }
    def execute(command, args:, context:)
      @builtin_executor.execute(command.builtin, args:, context:)
      if command.stamps?
        @project_executor.run_waiting(command.project, args:, context:)
      else
        @project_executor.exec_into(command.project, args:, context:)
      end
    end
  end
end
