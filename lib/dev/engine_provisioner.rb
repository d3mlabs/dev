# typed: strict
# frozen_string_literal: true

require "dev/build_container_config"
require "dev/colima_provisioner"
require "dev/container_engine"
require "dev/deps"
require "dev/docker_cli_plugins"
require "dev/settings"

module Dev
  # `dev up`'s engine half: bring the resolved container engine to a state
  # where `docker build` works for this project.
  #
  # What that takes depends on the host OS — one engine per OS, see
  # ContainerEngine:
  # - macOS: the brew docker CLI needs its buildx plugin registered, and the
  #   colima VM needs to be running (started sized from the repo's
  #   build.container.resources hint; colima sizes only at creation).
  # - Linux / WSL2: bare dockerd is a system service, nothing to start; the
  #   distro's docker packages ship buildx in place.
  # - An explicit DOCKER_HOST is the user's own engine and is left alone.
  class EngineProvisioner
    extend T::Sig

    # @param settings [Dev::Settings] carries the optional container_engine record
    # @param colima [Dev::ColimaProvisioner] starts the macOS VM
    # @param cli_plugins [Dev::DockerCliPlugins] wires brew's buildx into the CLI
    # @param host_os [String] "darwin" / "linux" / "windows"
    # @param env [Hash{String => String}] the process env (DOCKER_HOST wins)
    sig do
      params(
        settings: Dev::Settings,
        colima: Dev::ColimaProvisioner,
        cli_plugins: Dev::DockerCliPlugins,
        host_os: String,
        env: T::Hash[String, String],
      ).void
    end
    def initialize(settings: Dev::Settings.new, colima: Dev::ColimaProvisioner.new,
      cli_plugins: Dev::DockerCliPlugins.new, host_os: Dev::Deps.detect_host, env: ENV.to_h)
      @settings = settings
      @colima = colima
      @cli_plugins = cli_plugins
      @host_os = host_os
      @env = env
    end

    # Idempotently bring the engine up for a containerized project.
    #
    # @param resources [BuildContainerConfig::Resources, nil] the repo's VM sizing hint
    # @return [void]
    # @raise [ContainerEngine::UnknownEngineError] on an unrecognized container_engine record
    # @raise [ColimaProvisioner::StartFailedError] when the VM will not start
    sig { params(resources: T.nilable(BuildContainerConfig::Resources)).void }
    def provision!(resources:)
      engine = ContainerEngine.resolve(settings: @settings, env: @env, host_os: @host_os)
      return if engine.kind == :explicit

      @cli_plugins.ensure! if @host_os == "darwin"
      return unless engine.kind == :colima

      @colima.provision!(cpus: resources&.cpus, memory_gib: resources&.memory_gib)
    end
  end
end
