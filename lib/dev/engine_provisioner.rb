# typed: strict
# frozen_string_literal: true

require "dev/build_container_config"
require "dev/colima_provisioner"
require "dev/container_engine"
require "dev/deps"
require "dev/docker_cli_plugins"
require "dev/engine_resources"
require "dev/engine_resources_check"
require "dev/linux_engine_provisioner"
require "dev/settings"
require "dev/wsl_host"
require "dev/wsl_provisioner"

module Dev
  # The engine step shared by `dev up` and `dev runner register`: bring the
  # resolved container engine to a state where `docker build` works for this
  # project, sized to its build.container.resources hint.
  #
  # What that takes depends on the host OS — one engine per OS, see
  # ContainerEngine:
  # - macOS: the brew docker CLI needs its buildx plugin registered, and the
  #   colima VM needs to be running at least the size of the hint
  #   (ColimaProvisioner's ratchet).
  # - Linux: dockerd is converged as a system service with the invoking user
  #   in the docker group (LinuxEngineProvisioner, one sudo prompt when
  #   there is work). Nothing to size — the daemon has the whole machine.
  # - WSL2: the same dockerd converge inside the distro, then the VM's size
  #   is ratcheted through `%USERPROFILE%\.wslconfig` (WslProvisioner). dev
  #   lives inside that VM, so a grown config surfaces as a restart the user
  #   performs (`wsl --shutdown`), never one dev performs.
  # - An explicit DOCKER_HOST is the user's own engine and is left alone.
  #
  # Whatever the engine, the last step measures it against the hint
  # (EngineResourcesCheck): the ratchet may have been unable to grow the VM,
  # and bare dockerd has nothing dev can grow — either way `dev up` says so
  # here rather than letting the first build find out.
  class EngineProvisioner
    extend T::Sig

    # `stop!` asked of an engine dev did not provision and so never powers
    # off: an explicit DOCKER_HOST, or Docker Desktop behind a macOS `docker`
    # record.
    class UnmanagedEngineError < RuntimeError; end

    # What `dev engine status` renders: the resolved engine, whether it is
    # up, whether dev may stop it, its observed size, the per-kind facts
    # (exactly one of colima / linux is set for an engine dev provisions;
    # wsl joins linux inside a WSL2 distro), and what runs in it.
    class EngineStatus < T::Struct
      const :kind, Symbol
      const :running, T::Boolean
      const :stoppable, T::Boolean
      const :resources, T.nilable(EngineResources)
      const :colima, T.nilable(ColimaProvisioner::Vm)
      const :linux, T.nilable(LinuxEngineProvisioner::Status)
      const :wsl, T.nilable(WslHost::Status)
      const :containers, T::Array[ContainerEngine::RunningContainer]
    end

    # @param settings [Dev::Settings] carries the optional container_engine record
    # @param colima [Dev::ColimaProvisioner] starts the macOS VM
    # @param cli_plugins [Dev::DockerCliPlugins] wires brew's buildx into the CLI
    # @param resources_check [Dev::EngineResourcesCheck] the engine-vs-hint gate
    # @param wsl_host [Dev::WslHost] answers whether this Linux is a WSL2 distro
    # @param linux_engine [Dev::LinuxEngineProvisioner] converges dockerd on Linux/WSL
    # @param wsl [Dev::WslProvisioner] ratchets `.wslconfig` on WSL
    # @param host_os [String] "darwin" / "linux" / "windows"
    # @param env [Hash{String => String}] the process env (DOCKER_HOST wins)
    # @param engine [Dev::ContainerEngine, nil] the resolved engine; nil
    #   resolves it from settings/env/host_os (tests inject a fake docker)
    sig do
      params(
        settings: Dev::Settings,
        colima: Dev::ColimaProvisioner,
        cli_plugins: Dev::DockerCliPlugins,
        resources_check: Dev::EngineResourcesCheck,
        wsl_host: Dev::WslHost,
        linux_engine: Dev::LinuxEngineProvisioner,
        wsl: Dev::WslProvisioner,
        host_os: String,
        env: T::Hash[String, String],
        engine: T.nilable(ContainerEngine),
      ).void
    end
    def initialize(settings: Dev::Settings.new, colima: Dev::ColimaProvisioner.new,
      cli_plugins: Dev::DockerCliPlugins.new, resources_check: Dev::EngineResourcesCheck.new(settings: settings),
      wsl_host: Dev::WslHost.new, linux_engine: Dev::LinuxEngineProvisioner.new(wsl: wsl_host.wsl?),
      wsl: Dev::WslProvisioner.new(host: wsl_host), host_os: Dev::Deps.detect_host, env: ENV.to_h, engine: nil)
      @settings = settings
      @colima = colima
      @cli_plugins = cli_plugins
      @resources_check = resources_check
      @wsl_host = wsl_host
      @linux_engine = linux_engine
      @wsl = wsl
      @host_os = host_os
      @env = env
      @engine = engine
    end

    # The engine this provisioner acts on, resolved per the invoking user.
    #
    # @return [Dev::ContainerEngine]
    # @raise [ContainerEngine::UnknownEngineError] on an unrecognized container_engine record
    sig { returns(ContainerEngine) }
    def engine
      @engine ||= ContainerEngine.resolve(settings: @settings, env: @env, host_os: @host_os)
    end

    # Whether dev may power this engine off: one dev provisions (its colima
    # VM, the dockerd it converged on Linux/WSL). An explicit DOCKER_HOST
    # and Docker Desktop behind a macOS `docker` record are the user's own.
    #
    # @return [Boolean]
    sig { returns(T::Boolean) }
    def stoppable?
      engine.idle_stoppable? && !(engine.kind == :docker && @host_os == "darwin")
    end

    # Everything `dev engine status` shows, read live.
    #
    # @return [EngineStatus]
    sig { returns(EngineStatus) }
    def status
      colima = engine.kind == :colima ? @colima.status : nil
      linux = (engine.kind == :docker && @host_os == "linux") ? @linux_engine.status : nil
      wsl = (linux && @wsl_host.wsl?) ? @wsl_host.status : nil
      daemon = engine.resources
      running =
        if colima then colima.running
        elsif linux then linux.dockerd_active
        else !daemon.nil?
        end
      resources =
        if colima then EngineResources.new(cpus: colima.cpus, memory_gib: colima.memory_gib)
        elsif wsl then wsl.observed
        else daemon
        end
      EngineStatus.new(
        kind: engine.kind, running: running, stoppable: stoppable?, resources: resources,
        colima: colima, linux: linux, wsl: wsl, containers: engine.running_containers,
      )
    end

    # Power the engine off: the colima VM (the only way it reclaims RAM) or
    # dockerd on Linux/WSL (never the WSL VM). Whatever runs inside goes down
    # too — the caller (`dev engine down`) has already stopped dev's own
    # containers and asked about the user's.
    #
    # @return [void]
    # @raise [UnmanagedEngineError] on an engine dev did not provision
    # @raise [ColimaProvisioner::StopFailedError] when `colima stop` fails
    # @raise [LinuxEngineProvisioner::StepFailedError] when stopping dockerd fails
    sig { void }
    def stop!
      unless stoppable?
        raise UnmanagedEngineError, (
          if engine.kind == :explicit
            "DOCKER_HOST is set: that engine is yours, dev does not stop it (unset it to use dev's own)."
          else
            "the `docker` engine record on macOS rides Docker Desktop, which dev does not provision — " \
            "quit it from its menu, or `dev config set container_engine colima` to let dev own the engine."
          end
        )
      end

      engine.kind == :colima ? @colima.stop! : @linux_engine.stop!
    end

    # Idempotently bring the engine up for a containerized project.
    #
    # @param resources [BuildContainerConfig::Resources, nil] the repo's VM sizing hint
    # @return [void]
    # @raise [ContainerEngine::UnknownEngineError] on an unrecognized container_engine record
    # @raise [ColimaProvisioner::StartFailedError] when the VM will not start
    # @raise [ColimaProvisioner::EngineBusyError] when growing the colima VM would stop other projects' containers
    # @raise [LinuxEngineProvisioner::DesktopIntegrationError] when Docker Desktop's shim owns docker in the distro
    # @raise [LinuxEngineProvisioner::UnsupportedDistroError] on a Linux without apt-get
    # @raise [LinuxEngineProvisioner::StepFailedError] when an admin step fails
    # @raise [LinuxEngineProvisioner::RestartRequiredError] when a group join or wsl.conf change needs a restart
    # @raise [WslProvisioner::UnsatisfiableHintError] when the hint exceeds the Windows hardware
    # @raise [WslProvisioner::EngineBusyError] when growing the WSL VM would stop other projects' containers
    # @raise [WslProvisioner::RestartRequiredError] when `.wslconfig` is ahead of the running VM
    # @raise [EngineResourcesCheck::UndersizedEngineError] when the engine still falls short of the hint
    sig { params(resources: T.nilable(BuildContainerConfig::Resources)).void }
    def provision!(resources:)
      return if engine.kind == :explicit

      @cli_plugins.ensure! if @host_os == "darwin"
      @colima.provision!(cpus: resources&.cpus, memory_gib: resources&.memory_gib) if engine.kind == :colima
      actual = T.let(nil, T.nilable(EngineResources))
      if engine.kind == :docker && @host_os == "linux"
        # dockerd first: the WSL ratchet asks the local daemon who is busy.
        @linux_engine.provision!
        if @wsl_host.wsl?
          @wsl.provision!(cpus: resources&.cpus, memory_gib: resources&.memory_gib)
          # The daemon's MemTotal is what the guest kernel kept; the VM's size is the host's to report.
          actual = @wsl_host.observed
        end
      end

      @resources_check.check!(engine: engine, hint: resources, actual: actual)
    end
  end
end
