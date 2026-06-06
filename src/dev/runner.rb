# typed: strict
# frozen_string_literal: true

require 'pathname'
require 'dev/config_parser'
require 'dev/command_registry'
require 'dev/execution_context'
require 'dev/deps'
require 'dev/deps/resolver'
require 'dev/deps/lockfile'
require 'dev/cli/ui'

module Dev
  # Main entry: find repo, load config, build registry, parse argv, show usage or run command.
  class Runner
    extend T::Sig

    sig { params(dev_yaml_path: Pathname, cfg_parser: Dev::ConfigParser).void }
    def initialize(
      dev_yaml_path: Dev.dev_yaml_file,
      cfg_parser: Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
      )
      @cfg_parser = T.let(cfg_parser, Dev::ConfigParser)
      @config = T.let(@cfg_parser.parse(dev_yaml_path), Dev::Config)
      @registry = T.let(build_registry(@config), Dev::CommandRegistry)
    end

    # Runs the dev command specified by the given argv.
    #
    # @param argv [Array[String]] The argv to run the command with.
    # @param out [IO, StringIO] Stream for usage output (default: $stdout).
    # @param ui [Dev::Cli::Ui] CLI UI implementation for framing and formatting.
    # @return [void]
    sig { params(argv: T::Array[String], ui: Dev::Cli::Ui, out: T.any(IO, StringIO)).void }
    def run(argv, ui:, out: $stdout)
      if show_usage?(argv)
        print_usage(@config.name, @registry, out:)
        return
      end

      args = T.let(argv.dup, T::Array[String])
      cmd_name = T.must(args.shift)
      cmd = @registry.lookup(cmd_name)

      ruby_version = resolve_ruby_version(@config.ruby_version)
      context = ExecutionContext.new(ui:, ruby_version:, project_root: Dev::TARGET_PROJECT_ROOT)
      cmd.execute(args:, context:)
    rescue CommandRegistry::CommandNotFoundError => e
      $stderr.puts "dev: #{e}"
      $stderr.puts "Run 'dev' or 'dev --help' to see available commands."
      Kernel.exit(1)
    rescue ArgumentError, RuntimeError => e
      $stderr.puts "dev: #{e}"
      Kernel.exit(1)
    end

    private

    sig { params(config: Config).returns(CommandRegistry) }
    def build_registry(config)
      registry = CommandRegistry.new
      register_builtins(registry)
      config.commands.each { |name, cmd| registry.register(name, cmd) }
      registry
    end

    sig { params(registry: CommandRegistry).void }
    def register_builtins(registry)
      registry.register("update-deps", BuiltinCommand.new(
        desc: "Resolve dependency constraints and write lockfiles",
      ) do |args, context|
        deps_rb = context.project_root / "dependencies.rb"
        load(deps_rb.to_s) if deps_rb.exist?

        deps_config = Dev::Deps.define {}
        resolver = Dev::Deps::Resolver.new(repositories: {})
        lockfile = Dev::Deps::Lockfile.new(dir: context.project_root)
        resolved = resolver.resolve(deps_config.declarations)
        lockfile.lock(resolved)
      end)
    end

    sig { params(argv: T::Array[String]).returns(T::Boolean) }
    def show_usage?(argv)
      argv.empty? || argv == ["--help"] || argv == ["-h"]
    end

    sig { params(name: String, registry: CommandRegistry, out: T.any(IO, StringIO)).void }
    def print_usage(name, registry, out:)
      out.puts "Usage: dev <command> [args...]"
      out.puts ""
      out.puts "Commands for #{name}:"
      commands = registry.all
      if commands.empty?
        out.puts "  (no commands defined)"
      else
        commands.each do |cmd_name, command|
          out.puts "  #{cmd_name.ljust(12)} #{command.desc}"
        end
      end
      out.puts ""
      out.puts "Examples: dev up    dev up -v    dev update-deps    dev test"
    end

    sig { params(explicit_version: T.nilable(String)).returns(String) }
    def resolve_ruby_version(explicit_version)
      require "shadowenv_ruby"
      ShadowenvRuby.resolve_ruby_version(explicit_version)
    end
  end
end
