# typed: strict
# frozen_string_literal: true

require "dev/builtins/container_command"

module Dev
  module Builtins
    # `dev container reset` — remove this checkout's build containers, the
    # current tag's and any stale one, discarding their incremental state.
    # The next containerized command (or `dev container up`) creates a fresh
    # one from the image.
    class ContainerResetCommand < ContainerCommand
      extend T::Sig

      sig { override.returns(String) }
      def desc = "Remove this checkout's build container (discards its incremental state)"

      # @param args [Array<String>] unused
      # @param context [ExecutionContext] the project
      # @return [void]
      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        removed = client.reset_service!(context.project!.root)
        @out.puts(removed.empty? ? "dev: no build container to remove." : "dev: removed #{removed.join(", ")}.")
      end
    end
  end
end
