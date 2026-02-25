# typed: strict
# frozen_string_literal: true

require "open3"

require "dev/cli/ui"
require "dev/command"

module Dev
  # Runs dev commands in a repo: pretty UI for TTY, subprocess otherwise.
  class CommandRunner
    extend T::Sig

    sig { params(ui: Dev::Cli::Ui).void }
    def initialize(ui:)
      @ui = T.let(ui, Dev::Cli::Ui)
    end

    sig { params(cmd: Command).void }
    def run(cmd)
      if cmd.pretty_ui && tty?
        @ui.frame(cmd.run) { execute(cmd) }
        @ui.done
      else
        execute(cmd)
      end
    end

    private

    sig { returns(T::Boolean) }
    def tty?
      $stdout.tty?
    end
    
    sig { params(cmd: Command).void }
    def execute(cmd)
      if cmd.pretty_ui && tty?
        run_subprocess_with_capture(cmd)
      else
        run_replace_process(cmd)
      end
    end

    sig { params(cmd: Command).void }
    def run_replace_process(cmd)
      Dir.chdir(Dev::TARGET_PROJECT_ROOT)
      Kernel.exec(cmd.run)
    end

    sig { params(in_frame: T::Boolean).void }
    def run_subprocess(in_frame: false)
      if in_frame
        run_subprocess_with_capture
      else
        Dir.chdir(@root)
        exec(*T.unsafe(subprocess_exec_argv))
      end
    end

    sig { params(cmd: Command).returns(T::Array[String]) }
    def subprocess_exec_argv(cmd)
      ruby_version_file = Dev::TARGET_PROJECT_ROOT / ".ruby-version"
      if File.file?(ruby_version_file) && which_rbenv
          ["rbenv", "exec", @run_str, *@args]
      else
        [@run_str, *@args]
      end
    end

    sig { returns(T::Boolean) }
    def which_rbenv
      system("which", "rbenv", out: File::NULL, err: File::NULL) || false
    end

    sig { params(cmd: Command).void }
    def run_subprocess_with_capture(cmd)
      status = T.let(nil, T.nilable(Process::Status))
      Dir.chdir(Dev::TARGET_PROJECT_ROOT) do
        @ui.with_spinner("Running #{cmd.run}") do |spinner|
          Open3.popen2e(*T.unsafe(subprocess_exec_argv)) do |stdin, stdout_err, wait_thr|
            stdin.close
            stdout_err.each_line do |line|
              puts line
              stdout_err.flush
            end
            status = wait_thr.value
          end
        end
      end

      raise "cmd #{cmd.run} failed with status #{status.inspect}" unless status.success?
      # s = T.must(status)
      # exit(s.exitstatus || 1) unless s.success?
    end
  end
end
