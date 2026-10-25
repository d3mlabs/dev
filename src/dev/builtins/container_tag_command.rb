# typed: strict
# frozen_string_literal: true

require "dev/builtins/container_command"

module Dev
  module Builtins
    # `dev container tag` — the image reference this checkout resolves to:
    # the lock's pin (its tag is the content digest, dev#277) or, on the
    # deprecated path, the Dockerfile's content tag. Pure: no engine, no
    # network — so a workflow can capture it before the engine exists, and a
    # human can compare it with `docker images`. Goes with d3mlabs/dev#311.
    class ContainerTagCommand < ContainerCommand
      extend T::Sig

      sig { override.returns(String) }
      def desc = "Print the build image reference (no engine needed)"

      # @param args [Array<String>] unused
      # @param context [ExecutionContext] the project
      # @return [void]
      sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
      def call(args:, context:)
        @out.puts context.project!.project_image.ref
      end
    end
  end
end
