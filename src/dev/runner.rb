# frozen_string_literal: true

module Dev
  # Main entry: find repo, load config, parse argv, show usage or run command.
  class Runner
    def initialize(argv)
      @argv = argv.dup
    end

    def run
      root = RepoFinder.new(Dir.pwd).find
      unless root
        $stderr.puts "dev: no dev.yml found in current or parent directories"
        exit 1
      end

      config = ConfigLoader.new(root).load
      unless config
        $stderr.puts "dev: invalid dev.yml or no commands"
        exit 1
      end

      if show_usage?
        Usage.new(config).print
        exit 0
      end

      cmd_name = @argv.shift
      spec = config.command_spec(cmd_name)
      unless spec
        $stderr.puts "dev: unknown command #{cmd_name}"
        $stderr.puts "Run 'dev' or 'dev --help' to see available commands."
        exit 1
      end

      CliUi.new.enable
      CommandRunner.new(
        root: root,
        cmd_name: cmd_name,
        run_str: spec["run"],
        args: @argv
      ).run
    end

    private

    def show_usage?
      @argv.empty? || @argv == ["--help"] || @argv == ["-h"]
    end
  end
end
