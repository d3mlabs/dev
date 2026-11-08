# typed: strict
# frozen_string_literal: true

require "pathname"
require "stringio"
require "dev/build_dispatcher"
require "dev/build_listing"
require "dev/build_selector"
require "dev/builtin_executor"
require "dev/builtins"
require "dev/channel_binder"
require "dev/cli"
require "dev/command"
require "dev/command_executor"
require "dev/command_parser"
require "dev/command_repository"
require "dev/command_runner"
require "dev/command_service"
require "dev/dependency_service"
require "dev/deploy_selector"
require "dev/deps/lockfile"
require "dev/deps/staleness"
require "dev/dispatch_resolver"
require "dev/environment_image"
require "dev/execution_context"
require "dev/global_catalog"
require "dev/group_executor"
require "dev/host_rule"
require "dev/lifecycle"
require "dev/lifecycle_executor"
require "dev/overridden_executor"
require "dev/placement"
require "dev/placement_binder"
require "dev/project_container"
require "dev/project_executor"
require "dev/project_manifest"
require "dev/project_manifest_loader"
require "dev/project_publishers"
require "dev/remote_dispatches"
require "dev/runner_registry"
require "dev/runner_setup"

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

    # A channel with its protocol's placement — nil when the lock could not
    # place it at load.
    class BoundChannel < T::Struct
      const :channel, Lifecycle::Channel
      const :placement, T.nilable(Placement)
      # Why the channel cannot ship — a declared channel with no protocol
      # (ChannelBinder#faults). It lists; `deploy <channel>` refuses with
      # this; nothing else is affected (dev#509).
      const :fault, T.nilable(ChannelBinder::Fault), default: nil
    end

    # What binding the lock yields: the project commands with their
    # placements, the target placements the lifecycle verbs dispatch by,
    # the project's channels — the declared ones merged with the ones the
    # lock contributes (ChannelBinder) — each with the placement `deploy`
    # dispatches by, and the publishers the lock contributes, for Ports.
    class Bindings < T::Struct
      const :commands, T::Hash[String, ProjectNode]
      const :targets, T::Hash[String, TargetPlacement]
      const :channels, T::Hash[String, BoundChannel]
      const :publishers, T::Hash[String, Lifecycle::Publisher]
    end

    # Builds the deployment ledger over a checkout; injected for tests,
    # since the ledger is the forge.
    DeploymentsFactory = T.type_alias { T.proc.params(root: Pathname).returns(Lifecycle::GithubDeployments) }
    # Builds the release archive over a checkout; injected for the same reason.
    ReleasesFactory = T.type_alias { T.proc.params(root: Pathname).returns(Lifecycle::GithubReleases) }

    # The build hosts a run can leave this machine for, made once per run
    # and shared by the command runner and the lifecycle verbs: the
    # project's container (ProjectContainer) and the sync step that carries
    # the tree to any remote (Lifecycle::SnapshotSync).
    class RemoteHosts < T::Struct
      const :containers, ProjectContainer
      const :sync, Lifecycle::SnapshotSync
    end

    # Builds the remote hosts over a project; injected so tests hand in a
    # container over a fake engine and a sync step that touches no git.
    HostsFactory = T.type_alias { T.proc.params(project: ProjectContext).returns(RemoteHosts) }

    sig do
      params(
        ui: Dev::Cli::Ui,
        out: T.any(IO, StringIO),
        dev_yaml_path: T.nilable(Pathname),
        manifest_loader: ProjectManifestLoader,
        command_service: T.nilable(CommandService),
        host_rule: HostRule,
        hosts_factory: HostsFactory,
        deployments_factory: DeploymentsFactory,
        releases_factory: ReleasesFactory,
      ).void
    end
    def initialize(
      ui:,
      out: $stdout,
      dev_yaml_path: Dev.find_dev_yaml_file,
      manifest_loader: ProjectManifestLoader.new,
      command_service: nil,
      host_rule: HostRule.new,
      hosts_factory: lambda { |project|
        RemoteHosts.new(
          containers: ProjectContainer.new(project_root: project.root, engine_hint: project.engine),
          sync: Lifecycle::SnapshotSync.new(root: project.root),
        )
      },
      deployments_factory: ->(root) { Lifecycle::GithubDeployments.new(gh: Lifecycle::Gh.new(root:)) },
      releases_factory: ->(root) { Lifecycle::GithubReleases.new(gh: Lifecycle::Gh.new(root:)) }
    )
      @ui = ui
      @out = out
      @dev_yaml_path = dev_yaml_path
      @manifest_loader = manifest_loader
      @command_service = command_service
      # One answer to "does this image's work run here?" for the command
      # runner, the container bring-up and `dev up`'s inside check alike.
      @host_rule = host_rule
      @hosts_factory = hosts_factory
      @deployments_factory = deployments_factory
      @releases_factory = releases_factory
    end

    # Runs the dev command specified by the given argv.
    #
    # Composition happens here rather than in the constructor so that
    # everything — the dev.yml parse included, arbitrary project input —
    # stays inside the exit_for error mapping.
    #
    # @param argv [Array[String]] The argv to run the command with.
    # @return [void]
    sig { params(argv: T::Array[String]).void }
    def run(argv)
      manifest = @dev_yaml_path && @manifest_loader.load(@dev_yaml_path)
      context = build_context(manifest)
      service = @command_service || build_command_service(manifest, context)
      service.execute(argv, context:)
    rescue StandardError => e
      exit_for(e)
    end

    private

    # Assemble the per-run ExecutionContext: always the host half; the
    # project half only when a manifest exists.
    #
    # @param manifest [ProjectManifest, nil]
    # @return [ExecutionContext]
    sig { params(manifest: T.nilable(ProjectManifest)).returns(ExecutionContext) }
    def build_context(manifest)
      return ExecutionContext.new(ui: @ui) if manifest.nil?

      ExecutionContext.new(
        ui: @ui,
        project: ProjectContext.new(
          name: manifest.name,
          root: Dev.target_project_root,
          engine: manifest.engine,
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
      when Cli::FlagVocabulary::UsageError
        # Exit 2: the getopt/cobra convention for a malformed command line.
        Cli::UsagePrinter.new.print_usage_error(error, out: $stderr)
        Kernel.exit(2)
      when ArgumentError, RuntimeError, RunnerRegistry::QueryError, RunnerRegistry::AmendError, RunnerSetup::Error
        # The last three are GitHub's (or gh's) answer at the runner
        # boundary — a refusal, a failed query, an unresolvable checkout —
        # reported in GitHub's words, not re-raised as a dev bug (dev#493).
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
      # The printer says where each project command runs on this machine,
      # so it reads the same host rule the command runner places by.
      usage_printer = Cli::UsagePrinter.new(epilogue: PROJECT_EPILOGUE, host_rule: @host_rule)
      root_provider = -> { T.must(service).root }
      help = Builtins::HelpCommand.new(usage_printer:, out: @out, root_provider:)
      complete = Builtins::CompleteCommand.new(out: @out, root_provider:)
      bindings = bind_placements(manifest, context.project!)
      # The project's container as a build host (ADR-0008, dev#421), one
      # instance for the command runner and the lifecycle verbs alike, with
      # the sync step that carries the tree to it.
      hosts = @hosts_factory.call(context.project!)
      service = CommandService.new(
        repository: CommandRepository.new(
          root: CommandGroup.root(
            desc: "Development commands for #{manifest.name}",
            children: build_builtins(manifest, context.project!, dependency_service, help:, complete:, bindings:, ui: context.ui, hosts:),
          ),
          project_commands: bindings.commands,
        ),
        executor: build_executor(context, usage_printer, hosts:),
        dependency_service: dependency_service,
      )
      service
    end

    # Bind every lock-referencing name in dev.yml before the tree is
    # assembled (dev#409): each project command's `environment:`, each
    # target's per platform with the image capability check (dev#192,
    # K8), each channel's publisher against the publishers the lock
    # contributes — the declared channels merged with the contributed ones
    # (ChannelBinder, dev#422) — and each channel's protocol placement
    # (K5). An unknown or ambiguous name, a build pointed at an image that
    # does not produce its platform, a channel with neither `run:` nor a
    # contributed publisher, fails here, at load, and the usage printer
    # reads each command's placement; the target placements are what
    # `build` and `package` dispatch by (dev#414), the channel placements
    # what `deploy` does (dev#415).
    #
    # A lock out of step with the manifest — a pin locked by another dev's
    # template, a retired build-deps.lock, an image pinned before its block
    # declared the `target_platforms` a build now asks of it (dev#450) —
    # is a different failure: its remediation (`dev deps update`) is a
    # project builtin served by this very tree, so it must not make the
    # tree unbuildable. The commands stay in the tree unbound and no target
    # or channel is placed: the error's message goes to stderr once, help
    # lists the commands, builds and the declared channels (the lock's
    # contribution is unknown) without their environments, and a project
    # command, build or deploy asked to run refuses
    # (ProjectCommand#placement!, BuildDispatcher, DeployCommand) rather
    # than guess.
    #
    # @param manifest [ProjectManifest]
    # @param project [ProjectContext]
    # @return [Bindings]
    # @raise [ProjectImages::UnknownImageError, ProjectImages::AmbiguousEnvironmentImageError]
    sig { params(manifest: ProjectManifest, project: ProjectContext).returns(Bindings) }
    def bind_placements(manifest, project)
      binder = PlacementBinder.new(images: project.project_images)
      targets = binder.bind_targets(manifest.targets)
      project_publishers = ProjectPublishers.new(root: project.root)
      publishers = project_publishers.contributed
      channel_binder = ChannelBinder.new(publishers:, reach: project_publishers.reach, targets: manifest.targets.values)
      channels = channel_binder.bind(manifest.channels)
      faults = channel_binder.faults(manifest.channels)
      placements = binder.bind_channels(channels)
      bound = channels.to_h do |name, channel|
        fault = faults[name]
        [name, BoundChannel.new(channel:, placement: fault ? nil : placements.fetch(name), fault:)]
      end
      Bindings.new(commands: binder.bind(manifest.commands), targets:, channels: bound, publishers:)
    rescue EnvironmentImage::StaleDigestError, Deps::Lockfile::RetiredBuildLockError,
           PlacementBinder::ImageDoesNotProduceError => e
      $stderr.puts "dev: #{e.message}"
      unbound = manifest.channels.transform_values { |channel| BoundChannel.new(channel:, placement: nil) }
      Bindings.new(commands: manifest.commands, targets: {}, channels: unbound, publishers: {})
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
      usage_printer = Cli::UsagePrinter.new(epilogue: PROJECTLESS_EPILOGUE, host_rule: @host_rule)
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
    # composes them for the virtual-dispatch arm; the LifecycleExecutor
    # (the verbs' before → seam → after template, no process collaborator
    # of its own); the GroupExecutor shares help's printer and stream
    # (bare `dev` and `dev help` print the same root usage).
    #
    # @param context [ExecutionContext]
    # @param usage_printer [Cli::UsagePrinter]
    # @param hosts [RemoteHosts] the project's container and the sync step to it
    # @return [CommandExecutor]
    sig { params(context: ExecutionContext, usage_printer: Cli::UsagePrinter, hosts: RemoteHosts).returns(CommandExecutor) }
    def build_executor(context, usage_printer, hosts:)
      project = context.project!
      command_runner = CommandRunner.new(
        ui: context.ui,
        project_root: project.root,
        host_rule: @host_rule,
        containers: hosts.containers,
        sync: hosts.sync,
      )
      builtin_executor = BuiltinExecutor.new
      project_executor = ProjectExecutor.new(command_runner:)
      CommandExecutor.new(
        builtin_executor:,
        group_executor: GroupExecutor.new(usage_printer:, out: @out),
        project_executor:,
        overridden_executor: OverriddenExecutor.new(builtin_executor:, project_executor:),
        lifecycle_executor: LifecycleExecutor.new,
      )
    end

    # @param manifest [ProjectManifest]
    # @param project [ProjectContext] the run's project half (its images decide the container verbs)
    # @param dependency_service [DependencyService]
    # @param help [Builtins::HelpCommand] built by the caller, which owns
    #   the tree self-reference
    # @param complete [Builtins::CompleteCommand] likewise (the completion
    #   plumbing walks the same tree)
    # @param bindings [Bindings] where each target's builds and each
    #   channel's protocol run (both empty when the lock was unreadable)
    # @param ui [Cli::Ui] the run's UI, where a remote dispatch prints its crossing
    # @param hosts [RemoteHosts] the project's container and the sync step to it
    # @return [Hash{String => Command}] the root's children
    sig do
      params(
        manifest: ProjectManifest,
        project: ProjectContext,
        dependency_service: DependencyService,
        help: Builtins::HelpCommand,
        complete: Builtins::CompleteCommand,
        bindings: Bindings,
        ui: Cli::Ui,
        hosts: RemoteHosts,
      ).returns(T::Hash[String, Command])
    end
    def build_builtins(manifest, project, dependency_service, help:, complete:, bindings:, ui:, hosts:)
      install_deps = Builtins::InstallDepsCommand.new

      # The project's service dependencies — what `dev up` brings up after
      # the install and `dev down` takes down in reverse — as their ports,
      # in bring-up order. This is the one expression that decides
      # membership: the build containers (an environment service) when the
      # project has an image — the lock pins one
      # (ProjectImages#containerized?). The port objects are the very
      # instances the `container` verbs expose, so `dev up` and
      # `dev container up` are one operation with two entry points.
      services_up = T.let([], T::Array[Builtins::ServiceUp])
      services_down = T.let([], T::Array[Builtins::ServiceDown])
      container_group = T.let(nil, T.nilable(Command))
      if project.project_images.containerized?
        container_up = Builtins::ContainerUpCommand.new(out: @out, host_rule: @host_rule)
        container_down = Builtins::ContainerDownCommand.new(out: @out)
        services_up << container_up
        services_down << container_down
        container_group = container_builtins(up: container_up, down: container_down)
      end

      builtins = T.let({
        "help" => help,
        "complete" => complete,
        # `up` composes the same install `dev deps install` runs (the user's
        # intent, extended — it receives the args), then the services.
        "up" => Builtins::UpCommand.new(install_deps_command: install_deps, service_dependencies: services_up, host_rule: @host_rule),
        # Bundler's verbs: update ≈ bundle update, install ≈ bundle install,
        # check ≈ bundle check (inspect and exit non-zero when unsatisfied).
        "deps" => CommandGroup.new(
          path: ["deps"],
          desc: "Manage dependencies (update | install | check | path)",
          category: Command::Category::Environment,
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
        # Hidden plumbing for a target's `package:` script (dev#192): dev's
        # own archive forms over any directory.
        "pack" => Builtins::PackCommand.new(out: @out),
      }, T::Hash[String, Command])
      builtins["container"] = container_group if container_group
      # `down` reverses what `up` adds; a project with no service dependency
      # has nothing for it to bring down, so it exists iff the list does.
      unless services_down.empty?
        builtins["down"] = Builtins::DownCommand.new(service_dependencies: services_down, out: @out)
      end
      # The lifecycle verbs are derived from `targets:` (dev#192, K1, K4): a
      # project that declares none has nothing to build, so they are absent
      # rather than present and refusing. `deploy` likewise from the
      # channels (K5), which need targets to accept builds from.
      builtins.merge!(lifecycle_builtins(manifest, project, bindings, ui:, hosts:)) if manifest.targets.any?
      builtins.merge!(runner_builtins)
      # The global builtins are dispatched before the Runner (bin/dev); they
      # join the project tree so help lists one complete tree.
      builtins.merge!(GlobalCatalog.new(out: @out).commands)
      builtins
    end

    # The container verbs exist only where the lock pins an image: they are
    # this checkout's image and container, so a project without one has
    # nothing for them to act on (the engine's own verbs are global).
    #
    # @param up [Builtins::ContainerUpCommand] the instance `dev up` also holds as a port
    # @param down [Builtins::ContainerDownCommand] likewise for `dev down`
    # @return [Command]
    sig { params(up: Builtins::ContainerUpCommand, down: Builtins::ContainerDownCommand).returns(Command) }
    def container_builtins(up:, down:)
      CommandGroup.new(
        path: ["container"],
        desc: "Manage this checkout's build container (up | down | reset | status)",
        category: Command::Category::Environment,
        children: {
          "up" => up,
          "down" => down,
          "reset" => Builtins::ContainerResetCommand.new(out: @out),
          "status" => Builtins::ContainerStatusCommand.new(out: @out),
        },
      )
    end

    # `build` and `package` over the project's targets: one selector (argv →
    # build), one dispatcher (build → where it runs, under the host rule the
    # rest of the tree places by, or on a remote host — the remote
    # dispatches wired here over the checkout, dev#420), one store under
    # the data root, shared by both verbs so they agree on every name. The
    # project's `VERSION` file, when any, leads the build id. `deploy`,
    # when the project has channels — declared, or contributed by the
    # lock: the fan-out heading one command per channel, each selecting
    # from the same store or, under `--release`, from the same download of
    # the release's archives (dev#425), dispatching its protocol by the
    # channel's bound placement through the same resolver, and recording
    # into one ledger on the forge (K6) — which `deploy status`, the last
    # child, reads back per channel. `release`, when the project declares
    # what one contains (`commands: release:`, K4): the cut over this
    # checkout's git, the same `package` instance run per release build,
    # the release archive on the forge — the one `deploy --release` reads.
    #
    # @param manifest [ProjectManifest]
    # @param project [ProjectContext]
    # @param bindings [Bindings]
    # @param ui [Cli::Ui]
    # @param hosts [RemoteHosts] the project's container and the sync step to it
    # @return [Hash{String => Command}]
    sig do
      params(manifest: ProjectManifest, project: ProjectContext, bindings: Bindings, ui: Cli::Ui, hosts: RemoteHosts)
        .returns(T::Hash[String, Command])
    end
    def lifecycle_builtins(manifest, project, bindings, ui:, hosts:)
      targets = manifest.targets.values
      selector = BuildSelector.new(targets:)
      remotes = RemoteDispatches.new(root: project.root, ui:, out: @out, sync: hosts.sync, containers: hosts.containers)
      resolver = DispatchResolver.new(host_rule: @host_rule, remotes:)
      dispatcher = BuildDispatcher.new(placements: bindings.targets, resolver:)
      listing = BuildListing.new(targets:, dispatcher:)
      ports = Lifecycle::Ports.new(project_root: project.root, publishers: bindings.publishers)
      store = Lifecycle::Store.new(project_name: project.name, targets:)
      package = Builtins::PackageCommand.new(selector:, dispatcher:, listing:, ports:, store:, out: @out)
      verbs = T.let({
        "build" => Builtins::BuildCommand.new(selector:, dispatcher:, listing:, ports:, store:, out: @out),
        "package" => package,
      }, T::Hash[String, Command])
      # The forge's release archive is built lazily: a project with neither
      # `release:` nor channels never asks for a Gh.
      releases = T.let(nil, T.nilable(Lifecycle::GithubReleases))
      release = manifest.release
      if release
        releases = @releases_factory.call(project.root)
        verbs["release"] = Builtins::ReleaseCommand.new(
          release:,
          cut: Lifecycle::ReleaseCut.new(git: Lifecycle::Git.new(root: project.root)),
          package:,
          store:,
          releases:,
          listing:,
          out: @out,
        )
      end
      return verbs if bindings.channels.empty?

      deployments = @deployments_factory.call(project.root)
      release_archives = Lifecycle::ReleaseArchives.new(releases: releases || @releases_factory.call(project.root), store:, targets:)
      channels = bindings.channels.to_h do |name, bound|
        command = Builtins::DeployCommand.new(
          channel: bound.channel,
          selector: DeploySelector.new(channel: bound.channel, targets:, store:, release_archives:),
          ports:,
          store:,
          resolver:,
          placement: bound.placement,
          fault: bound.fault,
          deployments:,
          out: @out,
        )
        [name, command]
      end
      verbs["deploy"] = Builtins::DeployAllCommand.new(
        channels:,
        status: Builtins::DeployStatusCommand.new(channels: bindings.channels.values.map(&:channel), deployments:, out: @out),
        out: @out,
      )
      verbs
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
          desc: "Enroll, inspect or unenroll this host as a self-hosted runner",
          category: Command::Category::Environment,
          children: {
            "register" => Builtins::RunnerRegisterCommand.new,
            "status" => Builtins::RunnerStatusCommand.new,
            "unregister" => Builtins::RunnerUnregisterCommand.new,
          },
        ),
      }
    end
  end
end
