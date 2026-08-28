# typed: strict
# frozen_string_literal: true

require "dev/command"
require "build_container"

module Dev
  module Builtins
    # Teardown for the persistent build container, only where a project opts
    # in (build.container.persist — the composition root gates it).
    class ResetContainerCommand < BuiltinCommand
      extend T::Sig

      sig { override.returns(String) }
      def desc = "Remove the persistent build container (clears its incremental cache)"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Lifecycle

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        project = context.project!
        cfg = T.must(project.build_container)
        image_tag = BuildContainer.image_with_tag(cfg, project_root: project.root)
        removed = BuildContainer.reset_service!(image_tag, project.root)
        puts(removed.empty? ? "dev: no persistent build container to remove." : "dev: removed #{removed.join(", ")}.")
      end
    end
  end
end
