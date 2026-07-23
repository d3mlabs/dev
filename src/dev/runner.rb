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
require 'dev/cd'

module Dev
  # Main entry: find repo, load config, build registry, parse argv, show usage or run command.
  class Runner
    extend T::Sig

    # Raised when a project declares its Ruby in both dependencies.rb and
    # dev.yml. RuntimeError so Runner#run reports it as a clean `dev:` error.
    class ConflictingRubyDeclarationError < RuntimeError; end

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

      ruby_version = resolve_ruby_version(declared_ruby_version)
      context = ExecutionContext.new(
        ui:,
        ruby_version:,
        python_version: declared_python_version,
        project_root: Dev.target_project_root,
        build_container: @config.build_container,
        runner: @config.runner,
      )
      guard_staleness(cmd_name, context.project_root)
      provision_build_credentials if cmd_name == "up"
      cmd.execute(args:, context:)
      stamp_installed(cmd_name, context.project_root)
    rescue CommandRegistry::CommandNotFoundError => e
      $stderr.puts "dev: #{e}"
      $stderr.puts "Run 'dev' or 'dev --help' to see available commands."
      Kernel.exit(1)
    rescue ArgumentError, RuntimeError => e
      $stderr.puts "dev: #{e}"
      Kernel.exit(1)
    end

    private

    # Commands that ARE the staleness remediation (or its explicit check) —
    # nagging before them would block the very fix being run. `plan` is exempt
    # because it never touches dependencies and runs headlessly from Cursor
    # hooks, where a staleness warning would only add noise. `provide-image`
    # is exempt because it consumes the committed lockfiles directly (they are
    # inputs to the image's content hash) and runs on fresh CI checkouts where
    # no installed stamp exists yet.
    STALENESS_EXEMPT_COMMANDS = T.let(%w[up install-deps update-deps check plan provide-image].freeze, T::Array[String])

    # Two O(1) digest checks at every command start (see Dev::Deps::Staleness):
    # manifest vs lockfile, lockfile vs installed stamp. Warn on workstations;
    # error in CI, where a stale state is a pipeline bug, not a reminder.
    sig { params(cmd_name: String, project_root: Pathname).void }
    def guard_staleness(cmd_name, project_root)
      return if STALENESS_EXEMPT_COMMANDS.include?(cmd_name)

      require "dev/deps/staleness"
      messages = Dev::Deps::Staleness.new(project_root:).messages
      return if messages.empty?

      if Dev::Deps.detect_env == "ci"
        raise "stale dependency state:\n#{messages.map { |m| "  #{m}" }.join("\n")}"
      end

      messages.each { |m| $stderr.puts "dev: warning: #{m}" }
    end

    # Record the installed stamp after a fully-successful provisioning command
    # (`dev up` treats a stale stamp as its expected precondition and rewrites
    # it; `install-deps` is the CI-side install). Reached only when execute
    # didn't raise.
    sig { params(cmd_name: String, project_root: Pathname).void }
    def stamp_installed(cmd_name, project_root)
      return unless ["up", "install-deps"].include?(cmd_name)

      require "dev/deps/staleness"
      Dev::Deps::Staleness.new(project_root:).stamp_installed!
    end

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
      register_runner_builtins(registry, config)
      config.commands.each { |name, cmd| registry.register(name, cmd) }
      registry
    end

    # `dev runner-setup` registers the current host as a self-hosted GitHub
    # Actions runner — repo-scoped by default, org-scoped with `--org` (one
    # runner serving every repo in the org, the shape ai-flow's shared pools
    # want). Registered only when a project declares a `runner:` block, so the
    # command surfaces only where it applies. dev owns the install logic (one
    # shared implementation) so repos declare just their runner identity
    # instead of vendoring a bespoke setup script. `--labels`/`--dir`/`--name`
    # override the block for hosts that differ from the repo default (e.g.
    # registering the Mac org-wide from a repo whose block describes the CI
    # box).
    sig { params(registry: CommandRegistry, config: Config).void }
    def register_runner_builtins(registry, config)
      runner_config = config.runner
      return if runner_config.nil?

      registry.register("runner-setup", BuiltinCommand.new(
        desc: "Register this host as a self-hosted GitHub Actions runner (repo-scoped, or org-wide with --org)",
      ) do |args, context|
        require "dev/runner_setup"
        cfg = context.runner
        raise ArgumentError, "no `runner:` block in dev.yml" if cfg.nil?

        Dev::RunnerSetup.new(
          config: runner_config_with_flag_overrides(cfg, args),
          repo: parse_repo_flag(args),
          org: args.include?("--org"),
        ).run
      end)
    end

    # Commands for the build container, registered only when a project declares
    # one (build.container). dev owns the container's lifecycle, so these live
    # here rather than in each repo's dev.yml.
    sig { params(registry: CommandRegistry, config: Config).void }
    def register_container_builtins(registry, config)
      build_container = config.build_container
      return if build_container.nil?

      # The CLI verb for CI image provisioning: resolve the content-addressed
      # image (local → pull → build, see BuildContainer.ensure_image!) and
      # print its tag to stdout (resolution progress goes to stderr, so the
      # tag is capturable). Publishing to the shared registry stays gated on
      # DEV_PUBLISH_IMAGE, same as containerized commands. Hidden: workflow
      # plumbing, not a developer intent command.
      registry.register("provide-image", BuiltinCommand.new(
        desc: "Resolve the build container image (local/pull/build) and print its tag",
        hidden: true,
      ) do |_args, context|
        require "build_container"
        require "dev/credentials"
        cfg = context.build_container
        image_tag = BuildContainer.ensure_image!(
          cfg,
          project_root: context.project_root,
          push: false,
          publish: ENV["DEV_PUBLISH_IMAGE"] == "1",
          build_args_provider: -> { Dev::Credentials.resolve_build_args(cfg.build_args) },
          secrets_provider: -> { Dev::Credentials.resolve_build_args(cfg.build_secrets) },
        )
        puts image_tag
      end)

      # Teardown for the persistent container, only where a project opts in.
      return unless build_container.persist

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
        Dev::Deps.reset!
        load(deps_rb.to_s) if deps_rb.exist?

        deps_config = Dev::Deps.last_config || Dev::Deps.define {}
        resolver = Dev::Deps::Resolver.new(
          repositories: build_repositories(
            project_root: context.project_root,
            ruby_version_requirement: deps_config.ruby_version_requirement,
          ),
        )
        lockfile = Dev::Deps::Lockfile.new(dir: context.project_root)
        resolved = resolver.resolve(deps_config.declarations)
        # Record the manifest digest so the staleness check can tell whether
        # dependencies.rb changed after this resolution (Dev::Deps::Staleness).
        require "digest"
        manifest_digest = deps_rb.exist? ? Digest::SHA256.file(deps_rb.to_s).hexdigest : nil
        lockfile.lock(resolved, manifest_digest:)
        puts "dev: lockfiles updated — now run dev up to install."
      end)

      registry.register("install-deps", BuiltinCommand.new(
        desc: "Install locked dependencies handled on the host (e.g. gh releases)",
      ) do |args, context|
        install_locked_deps(context)
      end)

      # `up` is a virtual slot: the builtin installs locked deps, and a project
      # `up:` command in dev.yml overrides it into an OverriddenCommand — the
      # builtin install runs first (super()), then the project's provisioning.
      # Projects with only a dependencies.rb get `dev up` for free. `up` also
      # ensures the `dev cd` shell hook (idempotent) — provisioning is where
      # dev's RC hooks land, next to the shadowenv one.
      registry.register("up", BuiltinCommand.new(
        desc: "Install locked dependencies, then run the project's up command (if defined)",
      ) do |args, context|
        Dev::Cd::HookInstaller.new.ensure_installed
        install_locked_deps(context)
      end)

      # `dev cd` is dispatched globally (before dev.yml lookup) in bin/dev;
      # this registration only surfaces it in `dev --help`.
      registry.register("cd", BuiltinCommand.new(
        desc: "Jump to a checkout under $DEV_CD_ROOT (default ~/src) by fuzzy name",
      ) do |args, _context|
        Dev::Cd::Accessor.new.run(args)
      end)

      registry.register("check", BuiltinCommand.new(
        desc: "Check dependency state freshness (manifest vs lockfiles vs installed)",
      ) do |args, context|
        require "dev/deps/staleness"
        messages = Dev::Deps::Staleness.new(project_root: context.project_root).messages
        if messages.empty?
          puts "dev: dependency state is in sync (manifest, lockfiles, installed stamp)."
        else
          messages.each { |m| $stderr.puts "dev: #{m}" }
          Kernel.exit(1)
        end
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

      registry.register("plan", BuiltinCommand.new(
        desc: "Sync Cursor plans with GitHub issues (new/link/pull/push/status)",
      ) do |args, context|
        require "dev/plan"
        Dev::Plan::Accessor.new(project_root: context.project_root).run(args)
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

    # Parse an optional `--repo owner/name` / `--repo=owner/name` override for
    # `dev runner-setup`. Returns nil so RunnerSetup falls back to `gh repo view`.
    #
    # @param args [Array<String>]
    # @return [String, nil]
    sig { params(args: T::Array[String]).returns(T.nilable(String)) }
    def parse_repo_flag(args)
      parse_value_flag(args, "--repo")
    end

    # A copy of the dev.yml runner block with any `--labels` / `--dir` / `--name`
    # CLI overrides applied. The block describes the repo's default runner host;
    # overrides let a different host (e.g. the shared Mac registering org-wide)
    # reuse the same command without editing dev.yml.
    #
    # @param cfg [Dev::RunnerSetupConfig]
    # @param args [Array<String>]
    # @return [Dev::RunnerSetupConfig]
    sig { params(cfg: RunnerSetupConfig, args: T::Array[String]).returns(RunnerSetupConfig) }
    def runner_config_with_flag_overrides(cfg, args)
      RunnerSetupConfig.new(
        labels: parse_value_flag(args, "--labels") || cfg.labels,
        dir: parse_value_flag(args, "--dir") || cfg.dir,
        name: parse_value_flag(args, "--name") || cfg.name,
        version: cfg.version,
      )
    end

    # Parse `--flag value` / `--flag=value` from args; nil when absent.
    #
    # @param args [Array<String>]
    # @param flag [String]
    # @return [String, nil]
    sig { params(args: T::Array[String], flag: String).returns(T.nilable(String)) }
    def parse_value_flag(args, flag)
      idx = args.index(flag)
      return args[idx + 1] if idx && args[idx + 1]

      inline = args.find { |a| a.start_with?("#{flag}=") }
      inline&.split("=", 2)&.fetch(1)
    end

    # Build the integration-type -> Repository hash the Resolver consumes,
    # derived from the single Registry table (see lib/dev/deps/registry.rb).
    #
    # @param project_root [Pathname] project root, threaded to repositories that need it
    # @param ruby_version_requirement [String, nil] for the bundler-generated Gemfile
    # @return [Hash{Symbol => Dev::Deps::Repository}]
    sig do
      params(
        project_root: Pathname,
        ruby_version_requirement: T.nilable(String),
      ).returns(T::Hash[Symbol, Dev::Deps::Repository])
    end
    def build_repositories(project_root:, ruby_version_requirement: nil)
      require "dev/deps/registry"
      Dev::Deps::Registry.repositories(project_root:, ruby_version_requirement:)
    end

    # Build the integration-type -> Integration hash for host installs, derived
    # from the same Registry table. Host integrations install on the host (not the
    # build container) so their artifacts can be volume-mounted in (the UE engine,
    # the Satisfactory server, SML zips, cmake source deps), plus the host-side
    # types dev now owns end to end: gems (bundler), Lua rocks, and brew formulae.
    #
    # Install-time has no loaded dependencies.rb, so config-level inputs default:
    # Install everything the lockfiles pin for this machine — shared by the
    # `install-deps` and `up` builtins. Filtered to the detected env and host
    # OS so e.g. a Mac never downloads the Linux engine.
    #
    # @param context [ExecutionContext]
    sig { params(context: ExecutionContext).void }
    def install_locked_deps(context)
      lockfile = Dev::Deps::Lockfile.new(dir: context.project_root)
      installer = Dev::Deps::DependencyInstaller.new(
        lockfile: lockfile,
        integrations: build_host_integrations(
          project_root: context.project_root,
          python_version: context.python_version,
        ),
      )
      installer.install(env: Dev::Deps.detect_env, host: Dev::Deps.detect_host)
    end

    # taps is empty (custom-tap installs go through the container path) and the
    # bundler Gemfile is already generated, so no ruby version is needed here.
    #
    # @param project_root [Pathname] repo root threaded to integrations that need it
    # @param python_version [String, nil] the `python` toolchain version, for the
    #   pip integration to build the project venv with
    # @return [Hash{Symbol => Dev::Deps::Integration}]
    sig { params(project_root: Pathname, python_version: T.nilable(String)).returns(T::Hash[Symbol, Dev::Deps::Integration]) }
    def build_host_integrations(project_root:, python_version: nil)
      require "dev/deps/cache"
      require "dev/deps/registry"
      Dev::Deps::Registry.host_integrations(
        project_root:,
        cache: Dev::Deps::Cache.new,
        python_version:,
      )
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

    # The project's declared Ruby version: the first-class `ruby` directive in
    # dependencies.rb (where toolchains live), or dev.yml's `ruby:` for repos
    # without a deps manifest (e.g. dev itself). Declaring in both is an error —
    # a silent precedence would let the loser go stale and mislead readers. nil
    # when neither is set, so resolve_ruby_version can fall back to Homebrew Ruby.
    #
    # dev evaluates dependencies.rb under its own bootstrap Ruby, so reading it
    # here — before the project's interpreter is provisioned — is safe.
    sig { returns(T.nilable(String)) }
    def declared_ruby_version
      deps_rb = Dev.target_project_root / "dependencies.rb"
      from_deps = T.let(nil, T.nilable(String))
      if deps_rb.exist?
        Dev::Deps.reset!
        load(deps_rb.to_s)
        from_deps = Dev::Deps.last_config&.ruby_version_requirement
        from_deps = nil if from_deps&.empty?
      end

      if from_deps && @config.ruby_version
        raise ConflictingRubyDeclarationError,
          "Ruby is declared in both dependencies.rb (#{from_deps}) and dev.yml (#{@config.ruby_version}); " \
            "keep only the dependencies.rb `ruby` directive"
      end

      from_deps || @config.ruby_version
    rescue ConflictingRubyDeclarationError
      raise
    rescue StandardError => e
      $stderr.puts "dev: could not read `ruby` from dependencies.rb (#{e.message}); using dev.yml ruby:"
      @config.ruby_version
    end

    # The project's declared Python toolchain version from the first-class
    # `python` directive in dependencies.rb, or nil when unset. Read here (under
    # dev's bootstrap Ruby, before the project interpreter is provisioned) so it
    # can flow to command_runner (shadowenv provisioning) and the pip integration.
    sig { returns(T.nilable(String)) }
    def declared_python_version
      deps_rb = Dev.target_project_root / "dependencies.rb"
      return nil unless deps_rb.exist?

      Dev::Deps.reset!
      load(deps_rb.to_s)
      version = Dev::Deps.last_config&.python_version
      (version && !version.empty?) ? version : nil
    rescue StandardError => e
      $stderr.puts "dev: could not read `python` from dependencies.rb (#{e.message})"
      nil
    end
  end
end
