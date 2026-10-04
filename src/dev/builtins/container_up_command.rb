# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/builtins/container_command"
require "dev/builtins/service_up"
require "dev/container_deps_installer"
require "dev/container_dev_provisioner"
require "dev/credentials"
require "dev/engine_provisioner"

module Dev
  module Builtins
    # `dev container up` — everything a containerized command needs before it
    # runs, done ahead of time: the engine up and sized from this repo's hint,
    # the image resolved (local → registry → build), and, when the project
    # persists its container, the service container created or restarted
    # warm, its dev converged to the host's, and its side of the dependency
    # install run. `dev up` composes this after the host-side dependency
    # install; a CI job runs it alone to publish the image
    # (`DEV_PUBLISH_IMAGE=1`).
    #
    # The build container is this project's one service dependency (an
    # environment service: commands execute in it), so this is the
    # ServiceUp port `dev up` composes; `call` is the CLI adapter over it.
    class ContainerUpCommand < ContainerCommand
      extend T::Sig
      include ServiceUp

      # @param container_client [Dev::BuildContainer, nil]
      # @param engine_provisioner [Dev::EngineProvisioner] the sizing step
      # @param dev_provisioner [Dev::ContainerDevProvisioner, nil] converges
      #   the persistent container's dev to this host's version; resolved
      #   lazily over the client's engine when not injected, like the client
      # @param deps_installer [Dev::ContainerDepsInstaller, nil] runs the
      #   container-side dependency install; resolved lazily the same way
      # @param out [IO, StringIO]
      sig do
        params(
          container_client: T.nilable(Dev::BuildContainer),
          engine_provisioner: Dev::EngineProvisioner,
          dev_provisioner: T.nilable(Dev::ContainerDevProvisioner),
          deps_installer: T.nilable(Dev::ContainerDepsInstaller),
          out: T.any(IO, StringIO),
        ).void
      end
      def initialize(container_client: nil, engine_provisioner: Dev::EngineProvisioner.new,
                     dev_provisioner: nil, deps_installer: nil, out: $stdout)
        super(container_client:, out:)
        @engine_provisioner = engine_provisioner
        @dev_provisioner = dev_provisioner
        @deps_installer = deps_installer
      end

      sig { override.returns(String) }
      def desc = "Bring the engine up, resolve the build image, start the persistent container"

      # The CLI verb: an adapter over the ServiceUp port.
      #
      # @param args [Array<String>] unused
      # @param context [ExecutionContext] the project (the group is gated on build.container)
      # @return [void]
      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        up(project: context.project!)
      end

      # @param project [ProjectContext] the checkout (its build.container is the service's config)
      # @return [void]
      sig { override.params(project: ProjectContext).void }
      def up(project:)
        cfg = T.must(project.build_container)
        @engine_provisioner.provision!(resources: cfg.resources)

        image_tag = client.ensure_image!(
          cfg,
          project_root: project.root,
          push: false,
          publish: ENV["DEV_PUBLISH_IMAGE"] == "1",
          build_args_provider: -> { Dev::Credentials.resolve_build_args(cfg.build_args) },
          secrets_provider: -> { Dev::Credentials.resolve_build_args(cfg.build_secrets) },
        )
        @out.puts "dev: image ready: #{image_tag}"
        return unless cfg.persist

        volumes = BuildContainer.resolve_versioned_volumes(cfg.volumes, project_root: project.root)
        name = client.ensure_service!(image_tag, project_root: project.root, volumes: volumes)
        @out.puts "dev: build container up: #{name}"
        # The container follows the host: its dev is converged to this exact
        # version here, on every up, so a host upgrade re-syncs it with no
        # manual step and the steady state is one probe.
        result = dev_provisioner.provision!(name)
        @out.puts "dev: container dev #{result} at #{dev_provisioner.host_version}"
        # Dependencies install where they are consumed: with the container's
        # dev current, its side of the install runs there (gems against the
        # store Ruby, container-scoped brew deps), carrying the run_env the
        # install-time integrations may need.
        deps_installer.install!(name, env: Dev::Credentials.resolve_run_env(cfg.run_env))
        @out.puts "dev: container deps installed"
      end

      private

      # @return [Dev::ContainerDevProvisioner]
      sig { returns(Dev::ContainerDevProvisioner) }
      def dev_provisioner
        @dev_provisioner ||= Dev::ContainerDevProvisioner.new(engine: client.engine)
      end

      # @return [Dev::ContainerDepsInstaller]
      sig { returns(Dev::ContainerDepsInstaller) }
      def deps_installer
        @deps_installer ||= Dev::ContainerDepsInstaller.new(engine: client.engine)
      end
    end
  end
end
