# typed: strict
# frozen_string_literal: true

require_relative "command"
require_relative "command_runner"

module Dev
  # The process boundary for project commands: the only class that owns the
  # CommandRunner seam. The two child-process shapes are two precise
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

    # @param command_runner [CommandRunner] built once at the composition
    #   root from the run's ExecutionContext
    sig { params(command_runner: CommandRunner).void }
    def initialize(command_runner:)
      @command_runner = T.let(command_runner, CommandRunner)
    end

    # Hand the process over to the project command: exec-replace, the right
    # shape for a leaf command (TTY and signal passthrough, no double
    # process tree). The child's exit status becomes the process's own.
    #
    # @param command [ProjectCommand]
    # @param args [Array<String>] argv after the command name
    # @return [void] never returns
    # @raise [ExecReturnedError] if the exec boundary returns control
    sig { params(command: ProjectCommand, args: T::Array[String]).returns(T.noreturn) }
    def exec_into(command, args:)
      @command_runner.exec_into(command, args:)
      raise ExecReturnedError, "exec-mode CommandRunner returned instead of replacing the process"
    end

    # Run the project command spawn-and-wait, so control returns to the
    # caller's success-contingent post-steps (e.g. the installed stamp).
    #
    # @param command [ProjectCommand]
    # @param args [Array<String>] argv after the command name
    # @return [void]
    # @raise [CommandRunner::CommandFailedError] when the child fails,
    #   carrying its exit status
    sig { params(command: ProjectCommand, args: T::Array[String]).void }
    def run_waiting(command, args:)
      @command_runner.run_waiting(command, args:)
    end
  end
end
