# typed: strict
# frozen_string_literal: true

require 'pathname'
require 'dev/config_parser'
require 'dev/cli/ui'

module Dev
  # Raised when the user passes a command name that is not defined in dev.yml.
  class CommandNotFoundError < StandardError
    extend T::Sig

    sig { returns(String) }
    attr_reader :command_name

    sig { params(command_name: String).void }
    def initialize(command_name:)
      @command_name = command_name
      super("Command '#{command_name}' not defined in dev.yml")
    end
  end

  # Main entry: find repo, load config, parse argv, show usage or run command.
  class Runner
    extend T::Sig

    sig { params(dev_yaml_path: Pathname, cfg_parser: Dev::ConfigParser, ui: Dev::Cli::Ui).void }
    def initialize(
      dev_yaml_path,
      cfg_parser: Dev::ConfigParser.new(command_parser: Dev::CommandParser.new),
      ui: Dev::Cli::UiImpl.new(cli_ui: CLI::UI)
      )
      @dev_yaml_path = T.let(dev_yaml_path, Pathname)
      @cfg_parser = T.let(cfg_parser, Dev::ConfigParser)
      @ui = T.let(ui, Dev::Cli::Ui)
    end

    # Runs the dev command specified by the given argv.
    #
    # @param argv [Array[String]] The argv to run the command with.
    # @param out [IO::generic_writable] Stream for usage and normal output (default: $stdout).
    # @return [void]
    #
    # @raise [CommandNotFoundError] If the passed command is not defined in the config.
    # @raise [ArgumentError] If the command is not found.
    # @raise [RuntimeError] If the command fails.
    # @raise [SystemExit] If the command exits with a non-zero status.
    sig { params(argv: T::Array[String], out: T.any(IO, StringIO)).void }
    def run(argv, out: $stdout)
      args = T.let(argv.dup, T::Array[String])
      config = @cfg_parser.parse(@dev_yaml_path)
      if show_usage?(argv)
        config.print_usage(out: out)
        return
      end

      cmd_name = T.must(args.shift)
      begin
        cmd = config.command(cmd_name)
      rescue KeyError
        raise CommandNotFoundError.new(command_name: cmd_name)
      end

      cmd_runner = CommandRunner.new(root: File.dirname(@dev_yaml_path), ui: @ui)
      cmd_runner.run(cmd, args: args)
    rescue CommandNotFoundError, ArgumentError => e
      $stderr.puts "dev: #{e}"
      $stderr.puts "Run 'dev' or 'dev --help' to see available commands."
      Kernel.exit(1)
    rescue RuntimeError => e
      $stderr.puts "dev: #{e}"
      Kernel.exit(1)
    end

    private

    sig { params(argv: T::Array[String]).returns(T::Boolean) }
    def show_usage?(argv)
      argv.empty? || argv == ["--help"] || argv == ["-h"]
    end
  end
end
