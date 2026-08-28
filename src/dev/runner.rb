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
require "dev/overridden_executor"
require "dev/project_executor"
require "dev/project_manifest"
require "dev/project_manifest_loader"
require "shadowenv_ruby"

module Dev
  # The application service behind bin/dev, and the composition root of the
  # command onion: route argv to a command name (bare/--help/-h mean help),
  # assemble the ExecutionContext, wire the service graph, make one call
  # into CommandService, and map rescues to exits at the CLI boundary.
  #
  # The Runner is project-optional: with no enclosing dev.yml it still runs,
  # over the projectless catalog (just `up`, the fresh-box bootstrap) and a
  # context with no project half. Which commands exist is a registration
  # concern owned here; whether a command handles a missing project is the
  # command's own business logic.
  class Runner
    extend T::Sig

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
      @ui = T.let(ui, Dev::Cli::Ui)
      @out = T.let(out, T.any(IO, StringIO))
      @dev_yaml_path = T.let(dev_yaml_path, T.nilable(Pathname))
      @manifest_loader = T.let(manifest_loader, ProjectManifestLoader)
      @command_service = T.let(command_service, T.nilable(CommandService))
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
      cmd_name, args = route(argv)
      manifest = @dev_yaml_path && @manifest_loader.load(@dev_yaml_path)
      context = build_context(manifest)
      service = @command_service || build_command_service(manifest, context)
      service.execute(cmd_name, args:, context:)
    rescue StandardError => e
      exit_for(e)
    end

    private

    # Split argv into a command name and its arguments. Bare `dev` and the
    # conventional flags route to the help builtin; every other spelling
    # (including `dev help`) is a regular command lookup.
    #
    # @param argv [Array<String>]
    # @return [(String, Array<String>)]
    sig { params(argv: T::Array[String]).returns([String, T::Array[String]]) }
    def route(argv)
      return ["help", []] if argv.empty? || argv == ["--help"] || argv == ["-h"]

      args = argv.dup
      [T.must(args.shift), args]
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
          root: Dev.target_project_root,
          ruby_version: ShadowenvRuby.resolve_ruby_version(manifest.declared_ruby_version),
          python_version: manifest.declared_python_version,
          build_container: manifest.build_container,
          runner: manifest.runner,
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
        # particular name that failed to resolve against the tiny
        # projectless catalog.
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
    # CommandService, the onion rule) and the builtin set are constructed.
    # Which builtins exist is config-gated here — project builtins only with
    # a manifest, runner-setup only with a `runner:` block,
    # provide-image/reset-container only with a build container.
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
      # Help lists the catalog the service serves, and the service's
      # repository contains help — a self-reference by construction. The
      # provider captures the `service` local assigned below and
      # dereferences it only at call time, when it exists.
      service = T.let(nil, T.nilable(CommandService))
      help = Builtins::HelpCommand.new(
        project_name: manifest.name,
        usage_printer: Cli::UsagePrinter.new,
        out: @out,
        commands_provider: -> { T.must(service).visible_commands },
      )
      service = CommandService.new(
        repository: CommandRepository.new(
          builtins: build_builtins(manifest, dependency_service, help:),
          project_commands: manifest.commands,
        ),
        executor: build_executor(context),
        dependency_service: dependency_service,
      )
      service
    end

    # The projectless catalog: `up` is the one command that exists without a
    # project (its host half is the fresh-box bootstrap — install dev, `dev
    # up`, ready). The truly global commands (cd, clone, cred, ...) are
    # dispatched before the Runner; everything else requires the project, so
    # it simply isn't registered — a lookup miss maps to the no-dev.yml
    # refusal in exit_for.
    #
    # @return [CommandService]
    sig { returns(CommandService) }
    def build_projectless_command_service
      CommandService.new(
        repository: CommandRepository.new(
          builtins: { "up" => Builtins::UpCommand.new(install_deps_command: Builtins::InstallDepsCommand.new) },
          project_commands: {},
        ),
        executor: CommandExecutor.new(builtin_executor: BuiltinExecutor.new),
        dependency_service: NoProjectDependencyService.new,
      )
    end

    # Wire the executor composite: one CommandRunner (built from the run's
    # context, the process boundary's collaborators), one BuiltinExecutor,
    # and one ProjectExecutor, shared with the OverriddenExecutor that
    # composes them for the virtual-dispatch arm.
    #
    # @param context [ExecutionContext]
    # @return [CommandExecutor]
    sig { params(context: ExecutionContext).returns(CommandExecutor) }
    def build_executor(context)
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
        project_executor:,
        overridden_executor: OverriddenExecutor.new(builtin_executor:, project_executor:),
      )
    end

    # @param manifest [ProjectManifest]
    # @param dependency_service [DependencyService]
    # @param help [Builtins::HelpCommand] built by the caller, which owns
    #   the listing self-reference
    # @return [Hash{String => BuiltinCommand}] the builtin set
    sig do
      params(manifest: ProjectManifest, dependency_service: DependencyService, help: Builtins::HelpCommand)
        .returns(T::Hash[String, BuiltinCommand])
    end
    def build_builtins(manifest, dependency_service, help:)
      install_deps = Builtins::InstallDepsCommand.new
      builtins = T.let({
        "help" => help,
        "update-deps" => Builtins::UpdateDepsCommand.new,
        "install-deps" => install_deps,
        # `up` composes the same install the install-deps builtin runs.
        "up" => Builtins::UpCommand.new(install_deps_command: install_deps),
        "cd" => Builtins::CdCommand.new,
        "clone" => Builtins::CloneCommand.new,
        "learnings" => Builtins::LearningsCommand.new,
        "check" => Builtins::CheckCommand.new(dependency_service:),
        "deps" => Builtins::DepsCommand.new,
        "cache" => Builtins::CacheCommand.new,
        "config" => Builtins::ConfigCommand.new,
        "cred" => Builtins::CredCommand.new,
        "plan" => Builtins::PlanCommand.new,
      }, T::Hash[String, BuiltinCommand])
      builtins["provide-image"] = Builtins::ProvideImageCommand.new if manifest.build_container
      builtins["reset-container"] = Builtins::ResetContainerCommand.new if manifest.build_container&.persist
      builtins["runner-setup"] = Builtins::RunnerSetupCommand.new if manifest.runner
      builtins
    end
  end
end
