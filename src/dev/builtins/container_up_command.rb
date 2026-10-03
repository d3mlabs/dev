# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/builtins/container_command"
require "dev/credentials"
require "dev/engine_provisioner"

module Dev
  module Builtins
    # `dev container up` — everything a containerized command needs before it
    # runs, done ahead of time: the engine up and sized from this repo's hint,
    # the image resolved (local → registry → build), and, when the project
    # persists its container, the service container created or restarted
    # warm. `dev up` composes this after the dependency install; a CI job
    # runs it alone to publish the image (`DEV_PUBLISH_IMAGE=1`).
    class ContainerUpCommand < ContainerCommand
      extend T::Sig

      # @param container_client [Dev::BuildContainer, nil]
      # @param engine_provisioner [Dev::EngineProvisioner] the sizing step
      # @param out [IO, StringIO]
      sig do
        params(
          container_client: T.nilable(Dev::BuildContainer),
          engine_provisioner: Dev::EngineProvisioner,
          out: T.any(IO, StringIO),
        ).void
      end
      def initialize(container_client: nil, engine_provisioner: Dev::EngineProvisioner.new, out: $stdout)
        super(container_client:, out:)
        @engine_provisioner = engine_provisioner
      end

      sig { override.returns(String) }
      def desc = "Bring the engine up, resolve the build image, start the persistent container"

      # @param args [Array<String>] unused
      # @param context [ExecutionContext] the project (the group is gated on build.container)
      # @return [void]
      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        project = context.project!
        cfg = config(context)
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
      end
    end
  end
end
