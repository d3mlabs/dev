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
        removed = BuildContainer.reset_service!(image_tag, context.project_root)
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
          integrations: build_host_integrations(project_root: context.project_root),
        )
        installer.install(env: Dev::Deps.detect_env)
      end)

      registry.register("deps", BuiltinCommand.new(
        desc: "Inspect locked dependencies (e.g. deps path ficsit <mod> <platform>)",
      ) do |args, context|
        require "dev/deps/accessor"
        require "dev/deps/cache"
        Dev::Deps::Accessor.new(
          lockfile: Dev::Deps::Lockfile.new(dir: context.project_root),
          cache: Dev::Deps::Cache.new,
        ).run(args)
      end)

      registry.register("cache", BuiltinCommand.new(
        desc: "Manage host caches (e.g. cache gc --keep 2)",
      ) do |args, context|
        require "dev/deps/cache_gc"
        subcommand, *rest = args
        raise ArgumentError, "usage: dev cache gc [--keep N]" unless subcommand == "gc"

        gc = Dev::Deps::CacheGc.new(lockfile: Dev::Deps::Lockfile.new(dir: context.project_root))
        # The build container config (when present) lets GC also prune stale
        # content-tagged images while protecting the live tag.
        image_ref = nil
        live_tag = nil
        if (cfg = context.build_container)
          require "build_container"
          image_ref = cfg.image_ref
          live_tag = BuildContainer.image_with_tag(cfg, project_root: context.project_root)
        end
        gc.gc(keep: parse_gc_keep(rest), image_ref: image_ref, live_tag: live_tag)
      end)

      registry.register("cred", BuiltinCommand.new(
        desc: "Resolve a stored credential (e.g. cred get <namespace> <key>)",
      ) do |args, _context|
        require "dev/credentials"
        require "dev/credential_accessor"
        Dev::CredentialAccessor.new.run(args)
      end)
    end

    # Parse `--keep N` / `--keep=N` from `dev cache gc` args, defaulting to the
    # tight install-dir retention.
    #
    # @param args [Array<String>]
    # @return [Integer]
    sig { params(args: T::Array[String]).returns(Integer) }
    def parse_gc_keep(args)
      idx = args.index("--keep")
      return Integer(T.must(args[idx + 1])) if idx && args[idx + 1]

      flag = args.find { |a| a.start_with?("--keep=") }
      flag ? Integer(flag.split("=", 2).fetch(1)) : Dev::Deps::CacheGc::DEFAULT_KEEP
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
      require "dev/deps/steam_repository"

      git_repo = Dev::Deps::GitRepository.new
      {
        brew: Dev::Deps::BrewRepository.new,
        cmake: git_repo,
        luarocks: Dev::Deps::LuaRocksRepository.new,
        ficsit: Dev::Deps::FicsitRepository.new,
        gh: Dev::Deps::GhRepository.new,
        steam: Dev::Deps::SteamRepository.new,
      }
    end

    # Build the integrations that install on the host (not in the build
    # container) so they can be volume-mounted in:
    # - gh: the UE engine (install_dir, mounted at /ue)
    # - steam: the Satisfactory Dedicated Server (install_dir, mounted at /server)
    # - ficsit: SML zips, content-cached (~/.dev/cache, mounted read-only)
    # - cmake: C/C++ source deps fetched into the project (build/_deps/<name>-src,
    #   mounted via /project) — the one integration rooted in the project rather
    #   than a host cache, hence the project_root argument.
    #
    # @param project_root [Pathname] repo root the cmake integration fetches into
    # @return [Hash{Symbol => Dev::Deps::Integration}]
    sig { params(project_root: Pathname).returns(T::Hash[Symbol, Dev::Deps::Integration]) }
    def build_host_integrations(project_root:)
      require "dev/deps/cache"
      require "dev/deps/gh_repository"
      require "dev/deps/gh_integration"
      require "dev/deps/ficsit_repository"
      require "dev/deps/ficsit_integration"
      require "dev/deps/steam_repository"
      require "dev/deps/steam_integration"
      require "dev/deps/git_repository"
      require "dev/deps/cmake_integration"

      cache = Dev::Deps::Cache.new
      {
        gh: Dev::Deps::GhIntegration.new(
          repository: Dev::Deps::GhRepository.new,
          cache: cache,
        ),
        ficsit: Dev::Deps::FicsitIntegration.new(
          repository: Dev::Deps::FicsitRepository.new,
          cache: cache,
        ),
        steam: Dev::Deps::SteamIntegration.new(
          repository: Dev::Deps::SteamRepository.new,
          cache: cache,
        ),
        cmake: Dev::Deps::CmakeIntegration.new(
          repository: Dev::Deps::GitRepository.new,
          cache: cache,
          project_root: project_root,
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
      commands = registry.all.reject { |_name, command| command.hidden? }
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
