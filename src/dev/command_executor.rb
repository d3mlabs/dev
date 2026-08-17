# typed: strict
# frozen_string_literal: true

require_relative "command"
require_relative "command_runner"
require_relative "execution_context"

module Dev
  # The process boundary of a command run: exhaustive dispatch over the
  # sealed Command variants. Builtin bodies run in-process; project commands
  # hand the process over to the child through CommandRunner.
  class CommandExecutor
    extend T::Sig

    # @param command [Command]
    # @param args [Array<String>] argv after the command name
    # @param context [ExecutionContext]
    # @return [void]
    # @raise [CommandRunner::CommandFailedError] in wait mode, when the
    #   child command fails
    sig { params(command: Command, args: T::Array[String], context: ExecutionContext).void }
    def execute(command, args:, context:)
      case command
      when BuiltinCommand
        command.call(args:, context:)
      when ProjectCommand
        run_project(command, args:, context:, wait: false)
      when OverriddenCommand
        # Virtual dispatch: the builtin body is the hardcoded super(), then
        # the project command owns the slot.
        command.builtin.call(args:, context:)
        run_project(command.project, args:, context:, wait: command.stamps?)
      else
        T.absurd(command)
      end
    end

    private

    # Run a project command through CommandRunner. Wait-vs-exec derives from
    # the slot's stamping trait (the dev#85 invariant, enforced here in one
    # place): a stamping slot must spawn-and-wait so the caller can sequence
    # the installed stamp after execute — exec-replace would make it
    # unreachable. Generic project commands keep the exec tail-call (TTY and
    # signal passthrough, no double process tree).
    #
    # @param command [ProjectCommand]
    # @param args [Array<String>]
    # @param context [ExecutionContext]
    # @param wait [Boolean]
    # @return [void]
    # @raise [CommandRunner::CommandFailedError] in wait mode, when the
    #   child command fails
    sig do
      params(command: ProjectCommand, args: T::Array[String], context: ExecutionContext, wait: T::Boolean).void
    end
    def run_project(command, args:, context:, wait:)
      CommandRunner.new(
        ui: context.ui,
        ruby_version: context.ruby_version,
        python_version: context.python_version,
        build_container: context.build_container,
        project_root: context.project_root,
        wait: wait,
      ).run(command, args:)
    end
  end
end
