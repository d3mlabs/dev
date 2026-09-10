# typed: strict
# frozen_string_literal: true

require "dev/command"
require "dev/build_container"
require "dev/container_engine"

module Dev
  module Builtins
    # Teardown for the persistent build container, only where a project opts
    # in (build.container.persist — the composition root gates it).
    class ResetContainerCommand < BuiltinCommand
      extend T::Sig

      # @param container_client [Dev::BuildContainer, nil] override for tests;
      #   defaults to one over the invoking user's resolved engine
      sig { params(container_client: T.nilable(Dev::BuildContainer)).void }
      def initialize(container_client: nil)
        super()
        @container_client = container_client
      end

      sig { override.returns(String) }
      def desc = "Remove the persistent build container (clears its incremental cache)"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Lifecycle

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        project = context.project!
        cfg = T.must(project.build_container)
        image_tag = BuildContainer.image_with_tag(cfg, project_root: project.root)
        client = @container_client ||= BuildContainer.new(engine: Dev::ContainerEngine.resolve)
        removed = client.reset_service!(image_tag, project.root)
        puts(removed.empty? ? "dev: no persistent build container to remove." : "dev: removed #{removed.join(", ")}.")
      end
    end
  end
end
