# typed: strict
# frozen_string_literal: true

require_relative "command"
require_relative "command_runner"
require_relative "execution_context"

module Dev
  # The process boundary for project commands: the only class that owns the
  # CommandRunner/Kernel seam. The two child-process shapes are two precise
  # messages rather than a wait: flag — exec_into hands the process over to
  # the child (never returns), run_waiting spawns, waits, and raises on
  # child failure. Callers choose by sending the message they mean.
  class ProjectExecutor
    extend T::Sig

    # Raised when an exec-mode run returns control to dev. Kernel.exec
    # either replaces the process or raises (e.g. Errno::ENOENT), so a
    # normal return can only mean the exec boundary was faked out — this
    # keeps exec_into's never-returns contract honest even then.
    class ExecReturnedError < StandardError; end

    # Hand the process over to the project command: exec-replace, the right
    # shape for a leaf command (TTY and signal passthrough, no double
    # process tree). The child's exit status becomes the process's own.
    #
    # @param command [ProjectCommand]
    # @param args [Array<String>] argv after the command name
    # @param context [ExecutionContext]
    # @return [void] never returns
    # @raise [ExecReturnedError] if the exec boundary returns control
    sig { params(command: ProjectCommand, args: T::Array[String], context: ExecutionContext).returns(T.noreturn) }
    def exec_into(command, args:, context:)
      command_runner(context, wait: false).run(command, args:)
      raise ExecReturnedError, "exec-mode CommandRunner returned instead of replacing the process"
    end

    # Run the project command spawn-and-wait, so control returns to the
    # caller's success-contingent post-steps (e.g. the installed stamp).
    #
    # @param command [ProjectCommand]
    # @param args [Array<String>] argv after the command name
    # @param context [ExecutionContext]
    # @return [void]
    # @raise [CommandRunner::CommandFailedError] when the child fails,
    #   carrying its exit status
    sig { params(command: ProjectCommand, args: T::Array[String], context: ExecutionContext).void }
    def run_waiting(command, args:, context:)
      command_runner(context, wait: true).run(command, args:)
    end

    private

    # Assemble the CommandRunner for one run. Built per call because every
    # collaborator it needs arrives with the per-call ExecutionContext.
    #
    # @param context [ExecutionContext]
    # @param wait [Boolean]
    # @return [CommandRunner]
    sig { params(context: ExecutionContext, wait: T::Boolean).returns(CommandRunner) }
    def command_runner(context, wait:)
      CommandRunner.new(
        ui: context.ui,
        ruby_version: context.ruby_version,
        python_version: context.python_version,
        build_container: context.build_container,
        project_root: context.project_root,
        wait: wait,
      )
    end
  end
end
