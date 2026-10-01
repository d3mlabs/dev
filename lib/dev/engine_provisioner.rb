# typed: strict
# frozen_string_literal: true

require "dev/build_container_config"
require "dev/colima_provisioner"
require "dev/container_engine"
require "dev/deps"
require "dev/docker_cli_plugins"
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

    # @param settings [Dev::Settings] carries the optional container_engine record
    # @param colima [Dev::ColimaProvisioner] starts the macOS VM
    # @param cli_plugins [Dev::DockerCliPlugins] wires brew's buildx into the CLI
    # @param resources_check [Dev::EngineResourcesCheck] the engine-vs-hint gate
    # @param wsl_host [Dev::WslHost] answers whether this Linux is a WSL2 distro
    # @param linux_engine [Dev::LinuxEngineProvisioner] converges dockerd on Linux/WSL
    # @param wsl [Dev::WslProvisioner] ratchets `.wslconfig` on WSL
    # @param host_os [String] "darwin" / "linux" / "windows"
    # @param env [Hash{String => String}] the process env (DOCKER_HOST wins)
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
      ).void
    end
    def initialize(settings: Dev::Settings.new, colima: Dev::ColimaProvisioner.new,
      cli_plugins: Dev::DockerCliPlugins.new, resources_check: Dev::EngineResourcesCheck.new(settings: settings),
      wsl_host: Dev::WslHost.new, linux_engine: Dev::LinuxEngineProvisioner.new(wsl: wsl_host.wsl?),
      wsl: Dev::WslProvisioner.new(host: wsl_host), host_os: Dev::Deps.detect_host, env: ENV.to_h)
      @settings = settings
      @colima = colima
      @cli_plugins = cli_plugins
      @resources_check = resources_check
      @wsl_host = wsl_host
      @linux_engine = linux_engine
      @wsl = wsl
      @host_os = host_os
      @env = env
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
      engine = ContainerEngine.resolve(settings: @settings, env: @env, host_os: @host_os)
      return if engine.kind == :explicit

      @cli_plugins.ensure! if @host_os == "darwin"
      @colima.provision!(cpus: resources&.cpus, memory_gib: resources&.memory_gib) if engine.kind == :colima
      if engine.kind == :docker && @host_os == "linux"
        # dockerd first: the WSL ratchet asks the local daemon who is busy.
        @linux_engine.provision!
        @wsl.provision!(cpus: resources&.cpus, memory_gib: resources&.memory_gib) if @wsl_host.wsl?
      end

      @resources_check.check!(engine: engine, hint: resources)
    end
  end
end
