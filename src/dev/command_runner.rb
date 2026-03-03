# typed: strict
# frozen_string_literal: true

require "shellwords"

require "dev/cli/ui"
require "dev/command"

module Dev
  # Runs dev commands by exec-ing into the child process. Dev prints a colored
  # header (command name) and then replaces itself:
  #
  # - repl commands: exec directly (no footer, for interactive sessions)
  # - non-repl commands: exec into a shell wrapper that runs the command and
  #   prints ✓ Done / ✗ Failed based on exit code
  #
  # The child has full terminal access — CLI::UI features (frames, spinners,
  # prompts) all work natively without any interception.
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
      @ui.print_header(shell_command)

      if cmd.repl
        run_replace_process(shell_command)
      else
        run_exec_with_status(shell_command)
      end
    end

    private

    sig { params(run_str: String, args: T::Array[String]).returns(String) }
    def build_shell_command(run_str, args)
      return run_str if args.empty?

      "#{run_str} #{args.shelljoin}"
    end

    CHILD_ENV = T.let({ "GEM_HOME" => nil }.freeze, T::Hash[String, T.nilable(String)])

    sig { void }
    def ensure_shadowenv_provisioned!
      require "shadowenv_ruby"
      project_root = Dev::TARGET_PROJECT_ROOT
      return if ShadowenvRuby.provisioned?(@ruby_version, project_root: project_root)

      ShadowenvRuby.setup!(ruby_version: @ruby_version, project_root: project_root)
    end

    sig { params(shell_command: String).void }
    def run_replace_process(shell_command)
      Dir.chdir(Dev::TARGET_PROJECT_ROOT)
      Kernel.exec(CHILD_ENV, "shadowenv", "exec", "--", "sh", "-c", shell_command)
    end

    # Execs into a shell wrapper that runs the command, then prints a colored
    # success/failure footer based on the exit code.
    sig { params(shell_command: String).void }
    def run_exec_with_status(shell_command)
      Dir.chdir(Dev::TARGET_PROJECT_ROOT)
      Kernel.exec(CHILD_ENV, "shadowenv", "exec", "--", "sh", "-c", <<~SH)
        #{shell_command}
        __dev_status=$?
        if [ $__dev_status -eq 0 ]; then
          if [ -t 1 ]; then
            printf '\\033[32m✓\\033[0m Done\\n'
          else
            echo 'Done'
          fi
        else
          if [ -t 1 ]; then
            printf '\\033[31m✗\\033[0m Failed (exit %d)\\n' "$__dev_status"
          else
            printf 'Failed (exit %d)\\n' "$__dev_status"
          fi
          exit $__dev_status
        fi
      SH
    end
  end
end
