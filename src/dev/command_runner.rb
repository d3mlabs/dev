# typed: strict
# frozen_string_literal: true

require "pty"
require "shellwords"

require "dev/cli/ui"
require "dev/command"

module Dev
  # Runs dev commands: subprocess with output capture for pretty UI, or process
  # replacement for interactive commands (e.g. REPL).
  #
  # Before every command, ensures the project's shadowenv Ruby environment is
  # provisioned (fast-path: skips if .shadowenv.d/510_ruby.lisp is current).
  # All child commands are wrapped with `shadowenv exec --` so they inherit
  # the correct Ruby regardless of the user's shell state.
  class CommandRunner
    extend T::Sig

    sig { params(ui: Dev::Cli::Ui, ruby_version: String).void }
    def initialize(ui:, ruby_version:)
      @ui = T.let(ui, Dev::Cli::Ui)
      @ruby_version = T.let(ruby_version, String)
    end

    sig { params(cmd: Command, args: T::Array[String]).void }
    def run(cmd, args: [])
      ensure_shadowenv_provisioned!
      shell_command = build_shell_command(cmd.run, args)

      if !cmd.repl && tty?
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

    # Env overrides for child processes: unset GEM_HOME so the dev CLI's
    # Homebrew gem path doesn't leak into project commands (which use the
    # project's own Ruby/gems via shadowenv).
    CHILD_ENV = T.let({ "GEM_HOME" => nil }.freeze, T::Hash[String, T.nilable(String)])

    sig { void }
    def ensure_shadowenv_provisioned!
      require "shadowenv_ruby"
      project_root = Dev::TARGET_PROJECT_ROOT
      return if ShadowenvRuby.provisioned?(@ruby_version, project_root: project_root)

      ShadowenvRuby.setup!(ruby_version: @ruby_version, project_root: project_root)
    end

    # Replaces the current process with the command, wrapped in shadowenv exec
    # so the child inherits the project's Ruby environment.
    sig { params(shell_command: String).void }
    def run_replace_process(shell_command)
      Dir.chdir(Dev::TARGET_PROJECT_ROOT)
      Kernel.exec(CHILD_ENV, "shadowenv", "exec", "--", "sh", "-c", shell_command)
    end

    # Runs the command as a subprocess with a PTY so the child sees a real
    # terminal (preserving CLI::UI colors and spinner animations). Stdin is
    # inherited for interactive prompts; output streams through the PTY master
    # into the parent's stdout for CLI::UI frame borders.
    sig { params(shell_command: String).void }
    def run_subprocess_with_capture(shell_command)
      master, slave = T.unsafe(PTY).open
      slave.winsize = $stdout.winsize if $stdout.tty?

      pid = Process.spawn(
        CHILD_ENV,
        "shadowenv", "exec", "--", "sh", "-c", shell_command,
        chdir: Dev::TARGET_PROJECT_ROOT.to_s, in: $stdin, out: slave, err: slave
      )
      slave.close

      begin
        loop do
          $stdout.write(master.readpartial(4096))
          $stdout.flush
        end
      rescue EOFError, Errno::EIO
        # Expected when the child process exits and the PTY slave closes
      end
      master.close

      _, status = Process.wait2(pid)
      raise "#{shell_command} failed (exit #{T.must(status).exitstatus})" unless T.must(status).success?
    end
  end
end
