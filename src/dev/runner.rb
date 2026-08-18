# typed: strict
# frozen_string_literal: true

require "pathname"
require "stringio"
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
require "dev/project_manifest"
require "dev/project_manifest_loader"
require "shadowenv_ruby"

module Dev
  # The application service behind bin/dev, and the composition root of the
  # command onion: usage check, argv/context assembly, one call into
  # CommandService, and the rescue-to-exit mapping at the CLI boundary.
  class Runner
    extend T::Sig

    sig do
      params(
        dev_yaml_path: Pathname,
        manifest_loader: ProjectManifestLoader,
        command_service: T.nilable(CommandService),
      ).void
    end
    def initialize(
      dev_yaml_path: Dev.dev_yaml_file,
      manifest_loader: ProjectManifestLoader.new,
      command_service: nil
    )
      @manifest_loader = T.let(manifest_loader, ProjectManifestLoader)
      # The dev.yml side loads eagerly — usage needs the command list. The
      # dependencies.rb side waits for #run (see the toolchain pass there).
      @manifest = T.let(manifest_loader.load(dev_yaml_path), ProjectManifest)
      @command_service = T.let(command_service || build_command_service(@manifest), CommandService)
      @usage_printer = T.let(Cli::UsagePrinter.new, Cli::UsagePrinter)
    end

    # Runs the dev command specified by the given argv.
    #
    # @param argv [Array[String]] The argv to run the command with.
    # @param ui [Dev::Cli::Ui] CLI UI implementation for framing and formatting.
    # @param out [IO, StringIO] Stream for usage output (default: $stdout).
    # @return [void]
    sig { params(argv: T::Array[String], ui: Dev::Cli::Ui, out: T.any(IO, StringIO)).void }
    def run(argv, ui:, out: $stdout)
      if @usage_printer.show_usage?(argv)
        @usage_printer.print(project_name: @manifest.name, commands: @command_service.visible_commands, out:)
        return
      end

      args = T.let(argv.dup, T::Array[String])
      cmd_name = T.must(args.shift)
      # The toolchain pass runs here, after the usage check — `dev --help`
      # never loads the deps manifest (dependencies.rb is arbitrary Ruby).
      manifest = @manifest_loader.with_toolchain(@manifest, project_root: Dev.target_project_root)
      context = ExecutionContext.new(
        ui:,
        ruby_version: ShadowenvRuby.resolve_ruby_version(manifest.declared_ruby_version),
        python_version: manifest.declared_python_version,
        project_root: Dev.target_project_root,
        build_container: manifest.build_container,
        runner: manifest.runner,
      )
      @command_service.execute(cmd_name, args:, context:)
    rescue StandardError => e
      exit_for(e)
    end

    private

    # The rescue-to-exit mapping of the CLI boundary, in one place — the
    # counterpart of bin/dev's DevYamlNotFoundError handling. Errors keep
    # their native namespaces all the way up here (no service-layer
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
        $stderr.puts "dev: #{error}"
        $stderr.puts "Run 'dev' or 'dev --help' to see available commands."
        Kernel.exit(1)
      when ArgumentError, RuntimeError
        $stderr.puts "dev: #{error}"
        Kernel.exit(1)
      else
        raise error
      end
    end

    # The composition root: the one place the repository (private to this
    # onion) and the builtin set are constructed. Which builtins exist is
    # config-gated here — runner-setup only with a `runner:` block,
    # provide-image/reset-container only with a build container.
    #
    # @param manifest [ProjectManifest]
    # @return [CommandService]
    sig { params(manifest: ProjectManifest).returns(CommandService) }
    def build_command_service(manifest)
      dependency_service = DependencyService.new(
        staleness: Dev::Deps::Staleness.new(project_root: Dev.target_project_root),
      )
      CommandService.new(
        repository: CommandRepository.new(
          builtins: build_builtins(manifest, dependency_service),
          project_commands: manifest.commands,
        ),
        executor: CommandExecutor.new,
        dependency_service: dependency_service,
      )
    end

    # @param manifest [ProjectManifest]
    # @param dependency_service [DependencyService]
    # @return [Hash{String => BuiltinCommand}] the builtin set, in listing order
    sig do
      params(manifest: ProjectManifest, dependency_service: DependencyService)
        .returns(T::Hash[String, BuiltinCommand])
    end
    def build_builtins(manifest, dependency_service)
      install_deps = Builtins::InstallDepsCommand.new
      builtins = T.let({
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
