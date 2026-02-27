# typed: strict
# frozen_string_literal: true

require "shellwords"

require "dev/cli/ui"
require "dev/command"

module Dev
  # Runs dev commands: subprocess with output capture for pretty UI, or process
  # replacement for interactive commands (e.g. REPL).
  class CommandRunner
    extend T::Sig

    sig { params(ui: Dev::Cli::Ui).void }
    def initialize(ui:)
      @ui = T.let(ui, Dev::Cli::Ui)
    end

    sig { params(cmd: Command, args: T::Array[String]).void }
    def run(cmd, args: [])
      shell_command = build_shell_command(cmd.run, args)

      if cmd.pretty_ui && tty?
        @ui.frame(shell_command) { run_subprocess_with_capture(shell_command) }
        @ui.done
      else
        run_replace_process(shell_command)
      end
    end

    private

    sig { returns(T::Boolean) }
    def tty?
      $stdout.tty?
    end

    sig { params(run_str: String, args: T::Array[String]).returns(String) }
    def build_shell_command(run_str, args)
      return run_str if args.empty?

      "#{run_str} #{args.shelljoin}"
    end

    # Replaces the current process with the command. Used for interactive
    # commands (e.g. REPL) that need full terminal control.
    sig { params(shell_command: String).void }
    def run_replace_process(shell_command)
      Dir.chdir(Dev::TARGET_PROJECT_ROOT)
      Kernel.exec(shell_command)
    end

    # Runs the command as a subprocess with inherited stdin and captured
    # stdout/stderr. Stdin passthrough allows password prompts; piped output
    # flows through CLI::UI for frame borders.
    sig { params(shell_command: String).void }
    def run_subprocess_with_capture(shell_command)
      rd, wr = IO.pipe
      pid = Process.spawn(shell_command, chdir: Dev::TARGET_PROJECT_ROOT.to_s, in: $stdin, out: wr, err: wr)
      wr.close
      rd.each_line { |line| puts line }
      rd.close

      _, status = Process.wait2(pid)
      raise "#{shell_command} failed (exit #{T.must(status).exitstatus})" unless T.must(status).success?
    end
  end
end
