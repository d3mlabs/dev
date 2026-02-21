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
        $stderr.puts "dev: no dev.yml at project root (run from inside a git repo that has dev.yml at its root)"
        exit 1
      end

      dev_yml_path = File.join(root, RepoFinder::FILENAME)
      config = ConfigParser.new.parse(dev_yml_path)

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
      CommandRunner.new(root: root, interactive: spec["interactive"]).run(
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
