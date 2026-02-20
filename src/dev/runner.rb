# frozen_string_literal: true

module Dev
  # Main entry: find repo, load config, parse argv, show usage or run command.
  class Runner
    def self.run(argv)
      new(argv).run
    end

    def initialize(argv)
      @argv = argv.dup
    end

    def run
      root = RepoFinder.find
      unless root
        $stderr.puts "dev: no dev.yml found in current or parent directories"
        exit 1
      end

      config = ConfigLoader.load(root)
      unless config
        $stderr.puts "dev: invalid dev.yml or no commands"
        exit 1
      end

      if show_usage?
        Usage.print(config)
        exit 0
      end

      cmd_name = @argv.shift
      spec = config.command_spec(cmd_name)
      unless spec
        $stderr.puts "dev: unknown command #{cmd_name}"
        $stderr.puts "Run 'dev' or 'dev --help' to see available commands."
        exit 1
      end

      CliUi.enable
      CommandRunner.run(
        root: root,
        cmd_name: cmd_name,
        run_str: spec["run"],
        args: @argv
      )
    end

    private

    def show_usage?
      @argv.empty? || @argv == ["--help"] || @argv == ["-h"]
    end
  end
end
