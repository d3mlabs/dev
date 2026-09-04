# typed: strict
# frozen_string_literal: true

require_relative "builtin_executor"
require_relative "command"
require_relative "execution_context"
require_relative "overridden_executor"
require_relative "project_executor"

module Dev
  # The dispatching composite over the sealed Command variants: the case +
  # T.absurd sends each variant to its injected strategy and does nothing
  # else. Builtin bodies go to BuiltinExecutor (in-process), project
  # commands to ProjectExecutor's exec tail-call, overridden slots to
  # OverriddenExecutor (builtin stage, then the project tail).
  class CommandExecutor
    extend T::Sig

    # @param builtin_executor [BuiltinExecutor]
    # @param project_executor [ProjectExecutor]
    # @param overridden_executor [OverriddenExecutor]
    sig do
      params(
        builtin_executor: BuiltinExecutor,
        project_executor: ProjectExecutor,
        overridden_executor: OverriddenExecutor,
      ).void
    end
    def initialize(builtin_executor:, project_executor:, overridden_executor:)
      @builtin_executor = builtin_executor
      @project_executor = project_executor
      @overridden_executor = overridden_executor
    end

    # Dispatch one command to its strategy.
    #
    # @param command [Command]
    # @param args [Array<String>] argv after the command name
    # @param context [ExecutionContext]
    # @return [void]
    # @raise [CommandRunner::CommandFailedError] when a waited child fails
    sig { params(command: Command, args: T::Array[String], context: ExecutionContext).void }
    def execute(command, args:, context:)
      case command
      when BuiltinCommand
        @builtin_executor.execute(command, args:, context:)
      when ProjectCommand
        @project_executor.exec_into(command, args:)
      when OverriddenCommand
        @overridden_executor.execute(command, args:, context:)
      else
        # simplecov:disable — the sealed hierarchy leaves no fourth variant
        # to construct, so this arm is unreachable at runtime; T.absurd keeps
        # the static exhaustiveness proof.
        T.absurd(command)
        # simplecov:enable
      end
    end
  end
end
