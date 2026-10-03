# typed: strict
# frozen_string_literal: true

require "dev/builtins/container_command"

module Dev
  module Builtins
    # `dev container tag` — the content-addressed image tag this checkout
    # resolves to, computed from the Dockerfile and lockfiles alone. Pure:
    # no engine, no network — so a workflow can capture it before the engine
    # exists, and a human can compare it with `docker images`.
    class ContainerTagCommand < ContainerCommand
      extend T::Sig

      sig { override.returns(String) }
      def desc = "Print the content-addressed build image tag (no engine needed)"

      # @param args [Array<String>] unused
      # @param context [ExecutionContext] the project
      # @return [void]
      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        @out.puts BuildContainer.image_with_tag(config(context), project_root: context.project!.root)
      end
    end
  end
end
