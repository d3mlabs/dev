# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/command"
require "dev/build_container"
require "dev/container_engine"

module Dev
  module Builtins
    # What the five `dev container` verbs share: they exist only in a project
    # whose dev.yml declares `build.container` (the group is gated on it), and
    # they act through one BuildContainer over the invoking user's engine,
    # resolved lazily so a verb that never reaches docker (`tag`) never reads
    # the engine record.
    class ContainerCommand < BuiltinCommand
      extend T::Sig
      extend T::Helpers
      abstract!

      # @param container_client [Dev::BuildContainer, nil] the docker seam; resolved on first use when nil
      # @param out [IO, StringIO]
      sig { params(container_client: T.nilable(Dev::BuildContainer), out: T.any(IO, StringIO)).void }
      def initialize(container_client: nil, out: $stdout)
        super()
        @container_client = container_client
        @out = out
      end

      sig { override.returns(Command::Category) }
      def category = Command::Category::Lifecycle

      # The container verbs are lifecycle plumbing, never a staleness nag:
      # a fresh CI checkout has no stamp and `container up` is how it gets one.
      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      private

      # @return [Dev::BuildContainer]
      sig { returns(Dev::BuildContainer) }
      def client
        @container_client ||= BuildContainer.new(engine: Dev::ContainerEngine.resolve)
      end

      # The gate guarantees the config; T.must documents that.
      #
      # @param context [ExecutionContext]
      # @return [Dev::BuildContainerConfig]
      sig { params(context: ExecutionContext).returns(Dev::BuildContainerConfig) }
      def config(context)
        T.must(context.project!.build_container)
      end
    end
  end
end
