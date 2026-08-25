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

    # A project or overridden command reached a composite wired without its
    # project arms. Those variants are only registered when a project
    # exists, and the projectless wiring is builtin-only — so reaching this
    # is a dev wiring bug; the raise keeps the invariant explicit.
    class ProjectExecutionUnavailableError < StandardError; end

    # The project arms are optional: outside any project (no dev.yml) the
    # repository holds only builtins, so the projectless wiring passes just
    # the builtin arm.
    #
    # @param builtin_executor [BuiltinExecutor]
    # @param project_executor [ProjectExecutor, nil]
    # @param overridden_executor [OverriddenExecutor, nil]
    sig do
      params(
        builtin_executor: BuiltinExecutor,
        project_executor: T.nilable(ProjectExecutor),
        overridden_executor: T.nilable(OverriddenExecutor),
      ).void
    end
    def initialize(builtin_executor:, project_executor: nil, overridden_executor: nil)
      @builtin_executor = T.let(builtin_executor, BuiltinExecutor)
      @project_executor = T.let(project_executor, T.nilable(ProjectExecutor))
      @overridden_executor = T.let(overridden_executor, T.nilable(OverriddenExecutor))
    end

    # Dispatch one command to its strategy.
    #
    # @param command [Command]
    # @param args [Array<String>] argv after the command name
    # @param context [ExecutionContext]
    # @return [void]
    # @raise [CommandRunner::CommandFailedError] when a waited child fails
    # @raise [ProjectExecutionUnavailableError] when a project-scoped variant
    #   reaches a builtin-only composite (a wiring bug)
    sig { params(command: Command, args: T::Array[String], context: ExecutionContext).void }
    def execute(command, args:, context:)
      case command
      when BuiltinCommand
        @builtin_executor.execute(command, args:, context:)
      when ProjectCommand
        project_executor.exec_into(command, args:)
      when OverriddenCommand
        overridden_executor.execute(command, args:, context:)
      else
        # :nocov: — the sealed hierarchy leaves no fourth variant to
        # construct, so this arm is unreachable at runtime; T.absurd keeps
        # the static exhaustiveness proof.
        T.absurd(command)
        # :nocov:
      end
    end

    private

    # @return [ProjectExecutor]
    # @raise [ProjectExecutionUnavailableError]
    sig { returns(ProjectExecutor) }
    def project_executor
      @project_executor ||
        raise(ProjectExecutionUnavailableError, "project command dispatched to a builtin-only executor")
    end

    # @return [OverriddenExecutor]
    # @raise [ProjectExecutionUnavailableError]
    sig { returns(OverriddenExecutor) }
    def overridden_executor
      @overridden_executor ||
        raise(ProjectExecutionUnavailableError, "overridden command dispatched to a builtin-only executor")
    end
  end
end
