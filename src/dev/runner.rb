# typed: strict
# frozen_string_literal: true

require "pathname"
require "stringio"
require "dev/builtin_executor"
require "dev/builtins"
require "dev/cli"
require "dev/command"
require "dev/command_executor"
require "dev/command_parser"
require "dev/command_repository"
require "dev/command_runner"
require "dev/command_service"
require "dev/dependency_service"
require "dev/deps/staleness"
require "dev/execution_context"
require "dev/global_catalog"
require "dev/group_executor"
require "dev/overridden_executor"
require "dev/project_executor"
require "dev/project_manifest"
require "dev/project_manifest_loader"
require "dev/shadowenv_ruby"

module Dev
  # The application service behind bin/dev, and the composition root of the
  # command onion: assemble the ExecutionContext, wire the service graph
  # (the command tree under its root node), make one call into
  # CommandService with argv, and map rescues to exits at the CLI boundary.
  #
  # The Runner is project-optional: with no enclosing dev.yml it still runs,
  # over the projectless tree (`up`, `runner`, the global commands) and a
  # context with no project half. Which commands exist is a registration
  # concern owned here; whether a command handles a missing project is the
  # command's own business logic.
  class Runner
    extend T::Sig

    # The root usage's closing line inside a project.
    # The root listing already shows every command with its description, so
    # the closing line points into the tree rather than repeating rows.
    PROJECT_EPILOGUE = "Run 'dev help <command>' for a command's usage."
    # …and outside one: the real gap is the missing dev.yml.
    PROJECTLESS_EPILOGUE = "Run dev inside a project that defines a dev.yml to see its commands."

    sig do
      params(
        ui: Dev::Cli::Ui,
        out: T.any(IO, StringIO),
        dev_yaml_path: T.nilable(Pathname),
        manifest_loader: ProjectManifestLoader,
        command_service: T.nilable(CommandService),
      ).void
    end
    def initialize(
      ui:,
      out: $stdout,
      dev_yaml_path: Dev.find_dev_yaml_file,
      manifest_loader: ProjectManifestLoader.new,
      command_service: nil
    )
      @ui = ui
      @out = out
      @dev_yaml_path = dev_yaml_path
      @manifest_loader = manifest_loader
      @command_service = command_service
    end

    # Runs the dev command specified by the given argv.
    #
    # Composition happens here rather than in the constructor so that
    # everything — the dev.yml parse and the toolchain pass over
    # dependencies.rb, both arbitrary project input — stays inside the
    # exit_for error mapping.
    #
    # @param argv [Array[String]] The argv to run the command with.
    # @return [void]
    sig { params(argv: T::Array[String]).void }
    def run(argv)
      manifest = @dev_yaml_path && @manifest_loader.load(@dev_yaml_path)
      context = build_context(manifest)
      service = @command_service || build_command_service(manifest, context)
      service.execute(route(argv), context:)
    rescue StandardError => e
      exit_for(e)
    end

    private

    # The conventional help flags are spellings of bare `dev`, which
    # resolves to the tree's root and prints its usage; every other argv is
    # the command path the service resolves down the tree.
    #
    # @param argv [Array<String>]
    # @return [Array<String>]
    sig { params(argv: T::Array[String]).returns(T::Array[String]) }
    def route(argv)
      return [] if argv == ["--help"] || argv == ["-h"]

      argv
    end

    # Assemble the per-run ExecutionContext: always the host half; the
    # project half only when a manifest exists (the toolchain pass over
    # dependencies.rb runs there, once per invocation).
    #
    # @param manifest [ProjectManifest, nil]
    # @return [ExecutionContext]
    sig { params(manifest: T.nilable(ProjectManifest)).returns(ExecutionContext) }
    def build_context(manifest)
      return ExecutionContext.new(ui: @ui) if manifest.nil?

      manifest = @manifest_loader.with_toolchain(manifest, project_root: Dev.target_project_root)
      ExecutionContext.new(
        ui: @ui,
        project: ProjectContext.new(
          name: manifest.name,
          root: Dev.target_project_root,
          ruby_version: ShadowenvRuby.resolve_ruby_version(manifest.declared_ruby_version),
          python_version: manifest.declared_python_version,
          build_container: manifest.build_container,
        ),
      )
    end

    # The rescue-to-exit mapping of the CLI boundary, in one place. Errors
    # keep their native namespaces all the way up here (no service-layer
    # wrapping); anything unmapped is a dev bug and re-raises with its
    # backtrace.
    #
    # @param error [StandardError]
    # @return [void]
    sig { params(error: StandardError).void }
    def exit_for(error)
      case error
      when CommandRunner::CommandFailedError
        # The child already reported its failure (the shell wrapper prints
        # its ✗ Failed footer); preserve the child's exit code.
        Kernel.exit(error.exit_status)
      when CommandRunner::CommandKilledError
        # A signal killed the child before its footer could run, so report
        # here; exit 128 + signal number (shell convention).
        $stderr.puts "dev: #{error}"
        Kernel.exit(128 + error.signal)
      when CommandRunner::CommandSpawnError
        # The child never started, so nothing was reported; exit 127, the
        # shell's command-not-found convention.
        $stderr.puts "dev: #{error}"
        Kernel.exit(127)
      when CommandRepository::CommandNotFoundError
        # Outside a project the real gap is the missing dev.yml, not the
        # particular name that failed to resolve against the projectless
        # tree.
        if @dev_yaml_path.nil?
          $stderr.puts "dev: no dev.yml found in this directory or any parent."
          $stderr.puts "Run dev from inside a project that defines a dev.yml."
        else
          $stderr.puts "dev: #{error}"
          $stderr.puts "Run 'dev' or 'dev --help' to see available commands."
        end
        Kernel.exit(1)
      when ArgumentError, RuntimeError
        $stderr.puts "dev: #{error}"
        Kernel.exit(1)
      else
        raise error
      end
    end

    # The composition root: the one place the repository (consumed only by
    # CommandService, the onion rule) and the builtin tree under its root
    # node are constructed. Which builtins exist is config-gated here —
    # project builtins only with a manifest, the `container` verbs only
    # with a build container.
    #
    # @param manifest [ProjectManifest, nil]
    # @param context [ExecutionContext]
    # @return [CommandService]
    sig { params(manifest: T.nilable(ProjectManifest), context: ExecutionContext).returns(CommandService) }
    def build_command_service(manifest, context)
      return build_projectless_command_service if manifest.nil?

      dependency_service = DependencyService.new(
        staleness: Dev::Deps::Staleness.new(project_root: Dev.target_project_root),
      )
      # Help and completion walk the tree the service serves, and that tree
      # contains them — a self-reference by construction. The provider
      # captures the `service` local assigned below and dereferences it
      # only at call time, when it exists.
      service = T.let(nil, T.nilable(CommandService))
      usage_printer = Cli::UsagePrinter.new(epilogue: PROJECT_EPILOGUE)
      root_provider = -> { T.must(service).root }
      help = Builtins::HelpCommand.new(usage_printer:, out: @out, root_provider:)
      complete = Builtins::CompleteCommand.new(out: @out, root_provider:)
      service = CommandService.new(
        repository: CommandRepository.new(
          root: CommandGroup.root(
            desc: "Development commands for #{manifest.name}",
            children: build_builtins(manifest, dependency_service, help:, complete:),
          ),
          project_commands: manifest.commands,
        ),
        executor: build_executor(context, usage_printer),
        dependency_service: dependency_service,
      )
      service
    end

    # The projectless tree: `up` (its host half is the fresh-box bootstrap
    # — install dev, `dev up`, ready), `runner` (enrollment is a machine
    # concern; `--org` registration and `status` need no project), the
    # global commands (dispatched before the Runner in bin/dev, but listed
    # here so the root usage and `complete` show one whole tree outside a
    # project), and help/completion over that tree. Everything else
    # requires the project, so it simply isn't registered — a lookup miss
    # maps to the no-dev.yml refusal in exit_for.
    #
    # @return [CommandService]
    sig { returns(CommandService) }
    def build_projectless_command_service
      service = T.let(nil, T.nilable(CommandService))
      usage_printer = Cli::UsagePrinter.new(epilogue: PROJECTLESS_EPILOGUE)
      root_provider = -> { T.must(service).root }
      builtins = T.let(
        {
          "help" => Builtins::HelpCommand.new(usage_printer:, out: @out, root_provider:),
          "complete" => Builtins::CompleteCommand.new(out: @out, root_provider:),
          "up" => Builtins::UpCommand.new(install_deps_command: Builtins::InstallDepsCommand.new),
        },
        T::Hash[String, Command],
      )
      builtins.merge!(runner_builtins)
      builtins.merge!(GlobalCatalog.new(out: @out).commands)
      service = CommandService.new(
        repository: CommandRepository.new(
          root: CommandGroup.root(desc: "Commands available outside a project", children: builtins),
          project_commands: {},
        ),
        executor: CommandExecutor.new(
          builtin_executor: BuiltinExecutor.new,
          group_executor: GroupExecutor.new(usage_printer:, out: @out),
        ),
        dependency_service: NoProjectDependencyService.new,
      )
      service
    end

    # Wire the executor composite: one CommandRunner (built from the run's
    # context, the process boundary's collaborators), one BuiltinExecutor,
    # and one ProjectExecutor, shared with the OverriddenExecutor that
    # composes them for the virtual-dispatch arm; the GroupExecutor shares
    # help's printer and stream (bare `dev` and `dev help` print the same
    # root usage).
    #
    # @param context [ExecutionContext]
    # @param usage_printer [Cli::UsagePrinter]
    # @return [CommandExecutor]
    sig { params(context: ExecutionContext, usage_printer: Cli::UsagePrinter).returns(CommandExecutor) }
    def build_executor(context, usage_printer)
      project = context.project!
      command_runner = CommandRunner.new(
        ui: context.ui,
        ruby_version: project.ruby_version,
        python_version: project.python_version,
        build_container: project.build_container,
        project_root: project.root,
      )
      builtin_executor = BuiltinExecutor.new
      project_executor = ProjectExecutor.new(command_runner:)
      CommandExecutor.new(
        builtin_executor:,
        group_executor: GroupExecutor.new(usage_printer:, out: @out),
        project_executor:,
        overridden_executor: OverriddenExecutor.new(builtin_executor:, project_executor:),
      )
    end

    # @param manifest [ProjectManifest]
    # @param dependency_service [DependencyService]
    # @param help [Builtins::HelpCommand] built by the caller, which owns
    #   the tree self-reference
    # @param complete [Builtins::CompleteCommand] likewise (the completion
    #   plumbing walks the same tree)
    # @return [Hash{String => Command}] the root's children
    sig do
      params(
        manifest: ProjectManifest,
        dependency_service: DependencyService,
        help: Builtins::HelpCommand,
        complete: Builtins::CompleteCommand,
      ).returns(T::Hash[String, Command])
    end
    def build_builtins(manifest, dependency_service, help:, complete:)
      install_deps = Builtins::InstallDepsCommand.new
      builtins = T.let({
        "help" => help,
        "complete" => complete,
        # `up` composes the same install `dev deps install` runs.
        "up" => Builtins::UpCommand.new(install_deps_command: install_deps),
        # Bundler's verbs: update ≈ bundle update, install ≈ bundle install,
        # check ≈ bundle check (inspect and exit non-zero when unsatisfied).
        "deps" => CommandGroup.new(
          path: ["deps"],
          desc: "Manage dependencies (update | install | check | path)",
          category: Command::Category::Lifecycle,
          children: {
            "update" => Builtins::UpdateDepsCommand.new,
            "install" => install_deps,
            "check" => Builtins::CheckCommand.new(dependency_service:),
            "path" => Builtins::DepsPathCommand.new,
          },
        ),
        "cache" => CommandGroup.new(
          path: ["cache"],
          desc: "Manage host caches",
          category: Command::Category::Workflow,
          children: { "gc" => Builtins::CacheGcCommand.new },
        ),
      }, T::Hash[String, Command])
      if manifest.build_container
        builtins["container"] = container_builtins
        # `down` reverses what `up` adds for a containerized project; a
        # project without one has nothing for it to bring down.
        builtins["down"] = Builtins::DownCommand.new(out: @out)
      end
      builtins.merge!(runner_builtins)
      # The global builtins are dispatched before the Runner (bin/dev); they
      # join the project tree so help lists one complete tree.
      builtins.merge!(GlobalCatalog.new(out: @out).commands)
      builtins
    end

    # The container verbs exist only where `build.container` is declared:
    # they are this checkout's image and container, so a project without one
    # has nothing for them to act on (the engine's own verbs are global).
    #
    # @return [Command]
    sig { returns(Command) }
    def container_builtins
      CommandGroup.new(
        path: ["container"],
        desc: "Manage this checkout's build container (up | down | reset | tag | status)",
        category: Command::Category::Lifecycle,
        children: {
          "up" => Builtins::ContainerUpCommand.new(out: @out),
          "down" => Builtins::ContainerDownCommand.new(out: @out),
          "reset" => Builtins::ContainerResetCommand.new(out: @out),
          "tag" => Builtins::ContainerTagCommand.new(out: @out),
          "status" => Builtins::ContainerStatusCommand.new(out: @out),
        },
      )
    end

    # `runner` is ungated: enrollment is a machine concern (register derives
    # the repo label from the enclosing project; --org needs no project at
    # all), so the command exists everywhere — including the projectless
    # catalog.
    #
    # @return [Hash{String => Command}]
    sig { returns(T::Hash[String, Command]) }
    def runner_builtins
      {
        "runner" => CommandGroup.new(
          path: ["runner"],
          desc: "Enroll or inspect this host as a self-hosted runner",
          category: Command::Category::Lifecycle,
          children: {
            "register" => Builtins::RunnerRegisterCommand.new,
            "status" => Builtins::RunnerStatusCommand.new,
          },
        ),
      }
    end
  end
end
