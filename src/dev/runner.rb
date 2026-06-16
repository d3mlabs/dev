# typed: strict
# frozen_string_literal: true

require 'pathname'
require 'dev/config_parser'
require 'dev/command_registry'
require 'dev/execution_context'
require 'dev/deps'
require 'dev/deps/repository'
require 'dev/deps/integration'
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
      context = ExecutionContext.new(
        ui:,
        ruby_version:,
        project_root: Dev.target_project_root,
        build_container: @config.build_container,
      )
      provision_build_credentials if cmd_name == "up"
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

    # `dev up` is the provisioning command: after it succeeds, every other
    # command should work unattended. Resolving docker build args here
    # (prompting and storing credentials on first run) keeps the lazily
    # triggered image build in containerized commands non-interactive.
    sig { void }
    def provision_build_credentials
      config = @config.build_container
      return if config.nil? || config.build_args.empty?

      require "dev/credentials"
      Dev::Credentials.resolve_build_args(config.build_args)
    end

    sig { params(config: Config).returns(CommandRegistry) }
    def build_registry(config)
      registry = CommandRegistry.new
      register_builtins(registry)
      register_container_builtins(registry, config)
      config.commands.each { |name, cmd| registry.register(name, cmd) }
      registry
    end

    # Lifecycle commands for the persistent build container, registered only when
    # a project opts into it (build.container.persist). dev owns the container's
    # lifecycle, so the teardown lives here rather than in each repo's dev.yml.
    sig { params(registry: CommandRegistry, config: Config).void }
    def register_container_builtins(registry, config)
      build_container = config.build_container
      return unless build_container&.persist

      registry.register("reset-container", BuiltinCommand.new(
        desc: "Remove the persistent build container (clears its incremental cache)",
      ) do |_args, context|
        require "build_container"
        cfg = context.build_container
        image_tag = BuildContainer.image_with_tag(cfg, project_root: context.project_root)
        removed = BuildContainer.reset_service!(image_tag)
        puts(removed.empty? ? "dev: no persistent build container to remove." : "dev: removed #{removed.join(", ")}.")
      end)
    end

    sig { params(registry: CommandRegistry).void }
    def register_builtins(registry)
      registry.register("update-deps", BuiltinCommand.new(
        desc: "Resolve dependency constraints and write lockfiles",
      ) do |args, context|
        deps_rb = context.project_root / "dependencies.rb"
        load(deps_rb.to_s) if deps_rb.exist?

        deps_config = Dev::Deps.last_config || Dev::Deps.define {}
        resolver = Dev::Deps::Resolver.new(repositories: build_repositories)
        lockfile = Dev::Deps::Lockfile.new(dir: context.project_root)
        resolved = resolver.resolve(deps_config.declarations)
        lockfile.lock(resolved)
      end)

      registry.register("install-deps", BuiltinCommand.new(
        desc: "Install locked dependencies handled on the host (e.g. gh releases)",
      ) do |args, context|
        lockfile = Dev::Deps::Lockfile.new(dir: context.project_root)
        installer = Dev::Deps::DependencyInstaller.new(
          lockfile: lockfile,
          integrations: build_host_integrations,
        )
        installer.install(env: Dev::Deps.detect_env)
      end)
    end

    # Build the repositories hash mapping integration types to Repository instances.
    #
    # @return [Hash{Symbol => Dev::Deps::Repository}]
    sig { returns(T::Hash[Symbol, Dev::Deps::Repository]) }
    def build_repositories
      require "dev/deps/brew_repository"
      require "dev/deps/git_repository"
      require "dev/deps/url_repository"
      require "dev/deps/luarocks_repository"
      require "dev/deps/ficsit_repository"
      require "dev/deps/gh_repository"

      git_repo = Dev::Deps::GitRepository.new
      {
        brew: Dev::Deps::BrewRepository.new,
        cmake: git_repo,
        luarocks: Dev::Deps::LuaRocksRepository.new,
        ficsit: Dev::Deps::FicsitRepository.new,
        gh: Dev::Deps::GhRepository.new,
      }
    end

    # Build the integrations that install on the host (not in the build
    # container). Today that's only gh releases — the UE engine must land on
    # the host so it can be volume-mounted into the container.
    #
    # @return [Hash{Symbol => Dev::Deps::Integration}]
    sig { returns(T::Hash[Symbol, Dev::Deps::Integration]) }
    def build_host_integrations
      require "dev/deps/cache"
      require "dev/deps/gh_repository"
      require "dev/deps/gh_integration"

      {
        gh: Dev::Deps::GhIntegration.new(
          repository: Dev::Deps::GhRepository.new,
          cache: Dev::Deps::Cache.new,
        ),
      }
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
