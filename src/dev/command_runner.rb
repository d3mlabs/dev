# frozen_string_literal: true

module Dev
  # Runs a dev command: in-process for Ruby scripts (so they inherit CLI::UI), subprocess otherwise.
  class CommandRunner
    def initialize(root:, cmd_name:, run_str:, args:, interactive: nil)
      @root = root
      @cmd_name = cmd_name
      @run_str = run_str.to_s.strip
      @args = args
      @interactive = interactive
    end

    def run
      script_path = resolve_ruby_script
      title = @cmd_name.to_s.tr("-", " ").split.map(&:capitalize).join(" ")

      # Interactive commands (e.g. console/REPL) need a real TTY; don't run inside a Frame.
      if interactive? || !tty? || !cli_ui_available?
        run_without_frame(script_path)
      else
        run_with_frame(title, script_path)
      end
    end

    private

    def resolve_ruby_script
      return nil unless ruby_script?(@run_str)
      path = @run_str.start_with?("bin/") ? @run_str : @run_str.sub(/\A\.\//, "")
      full = File.expand_path(path, @root)
      File.file?(full) ? full : nil
    end

    def ruby_script?(s)
      s.end_with?(".rb") && (s.start_with?("./") || s.start_with?("bin/"))
    end

    def tty?
      $stdout.tty?
    end

    def cli_ui_available?
      defined?(CLI::UI)
    end

    def interactive?
      @interactive == true
    end

    def run_with_frame(title, script_path)
      CLI::UI::Frame.open(title) do
        execute(script_path, in_frame: true)
        puts CLI::UI.fmt("{{green:✓}} Done")
      end
    end

    def run_without_frame(script_path)
      execute(script_path, in_frame: false)
    end

    def execute(script_path, in_frame: false)
      if script_path
        run_ruby_in_process(script_path)
      else
        run_subprocess(in_frame: in_frame)
      end
    end

    def run_ruby_in_process(script_path)
      Dir.chdir(@root)
      ARGV.replace(@args)
      $PROGRAM_NAME = script_path
      load script_path
    rescue SystemExit => e
      exit(e.status || 0)
    end

    def run_subprocess(in_frame: false)
      if in_frame
        run_subprocess_with_capture
      else
        Dir.chdir(@root)
        exec(@run_str, *@args)
      end
    end

    def run_subprocess_with_capture
      require "open3"
      status = nil
      Dir.chdir(@root) do
        Open3.popen2e(@run_str, *@args) do |stdin, stdout_err, wait_thr|
          stdin.close
          stdout_err.each_line do |line|
            puts line
            $stdout.flush
          end
          status = wait_thr.value
        end
      end
      exit(status.exitstatus || 1) unless status.success?
    end
  end
end
