# typed: strict
# frozen_string_literal: true

module Dev
  # Runs dev commands in a repo: in-process for Ruby scripts (so they inherit CLI::UI), subprocess otherwise.
  # Constructor holds shared context (root) and runner config (e.g. interactive); run holds operation parameters.
  class CommandRunner
    extend T::Sig

    sig { params(root: String, interactive: T::Boolean).void }
    def initialize(root:, interactive: false)
      @root = T.let(root, String)
      @interactive = T.let(interactive, T::Boolean)
      @cmd_name = T.let("", String)
      @run_str = T.let("", String)
      @args = T.let([], T::Array[String])
    end

    sig { params(cmd_name: String, run_str: String, args: T::Array[String]).void }
    def run(cmd_name:, run_str:, args:)
      @cmd_name = cmd_name
      @run_str = run_str.strip
      @args = args

      script_path = resolve_ruby_script
      title = @cmd_name.tr("-", " ").split.map(&:capitalize).join(" ")

      if @interactive || !tty?
        run_without_frame(script_path)
      else
        run_with_frame(title, script_path)
      end
    end

    private

    sig { returns(T.nilable(String)) }
    def resolve_ruby_script
      return nil unless ruby_script?(@run_str)
      path = @run_str.start_with?("bin/") ? @run_str : @run_str.sub(/\A\.\//, "")
      full = File.expand_path(path, @root)
      File.file?(full) ? full : nil
    end

    sig { params(s: String).returns(T::Boolean) }
    def ruby_script?(s)
      s.end_with?(".rb") && (s.start_with?("./") || s.start_with?("bin/"))
    end

    sig { returns(T::Boolean) }
    def tty?
      $stdout.tty?
    end

    sig { params(title: String, script_path: T.nilable(String)).void }
    def run_with_frame(title, script_path)
      CLI::UI::Frame.open(title) do
        execute(script_path, in_frame: true)
        puts CLI::UI.fmt("{{green:✓}} Done")
      end
    end

    sig { params(script_path: T.nilable(String)).void }
    def run_without_frame(script_path)
      execute(script_path, in_frame: false)
    end

    sig { params(script_path: T.nilable(String), in_frame: T::Boolean).void }
    def execute(script_path, in_frame: false)
      if script_path && !in_frame
        run_ruby_in_process(script_path)
      else
        run_subprocess(in_frame: in_frame)
      end
    end

    sig { params(script_path: String).void }
    def run_ruby_in_process(script_path)
      Dir.chdir(@root)
      ARGV.replace(@args)
      $PROGRAM_NAME = script_path
      load script_path
    rescue SystemExit => e
      exit(e.status)
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

    sig { returns(T::Array[String]) }
    def subprocess_exec_argv
      ruby_version_file = File.join(@root, ".ruby-version")
      if File.file?(ruby_version_file) && which_rbenv
        script_path = resolve_run_str_to_path
        if script_path.start_with?("/")
          ["rbenv", "exec", "ruby", script_path, *@args]
        else
          ["rbenv", "exec", @run_str, *@args]
        end
      else
        [@run_str, *@args]
      end
    end

    sig { returns(String) }
    def resolve_run_str_to_path
      path = @run_str.sub(/\A\.\//, "").strip
      expanded = File.expand_path(path, @root)
      File.file?(expanded) ? expanded : @run_str
    end

    sig { returns(T::Boolean) }
    def which_rbenv
      system("which", "rbenv", out: File::NULL, err: File::NULL) || false
    end

    sig { void }
    def run_subprocess_with_capture
      require "open3"
      status = T.let(nil, T.nilable(Process::Status))
      Dir.chdir(@root) do
        Open3.popen2e(*T.unsafe(subprocess_exec_argv)) do |stdin, stdout_err, wait_thr|
          stdin.close
          stdout_err.each_line do |line|
            puts line
            $stdout.flush
          end
          status = wait_thr.value
        end
      end
      s = T.must(status)
      exit(s.exitstatus || 1) unless s.success?
    end
  end
end
