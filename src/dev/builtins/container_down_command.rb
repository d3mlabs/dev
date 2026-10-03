# typed: strict
# frozen_string_literal: true

require "dev/builtins/container_command"
require "dev/builtins/service_down"

module Dev
  module Builtins
    # `dev container down` — stop this checkout's running build containers,
    # keeping them: the writable layer (the build tool's incremental state)
    # is what `persist` buys, and `dev container up` restarts it warm. Other
    # checkouts' containers are untouched; `dev engine down` is the verb that
    # reaches across checkouts.
    #
    # The ServiceDown port `dev down` composes for the build container
    # service; `call` is the CLI adapter over it.
    class ContainerDownCommand < ContainerCommand
      extend T::Sig
      include ServiceDown

      sig { override.returns(String) }
      def desc = "Stop this checkout's build container, keeping its incremental state"

      # The CLI verb: an adapter over the ServiceDown port.
      #
      # @param args [Array<String>] unused
      # @param context [ExecutionContext] the project
      # @return [void]
      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        down(project: context.project!)
      end

      # @param project [ProjectContext] the checkout whose containers to stop
      # @return [void]
      # @raise [Dev::BuildContainer::StopFailedError] when a container will not stop
      sig { override.params(project: ProjectContext).void }
      def down(project:)
        stopped = client.stop_service!(project.root)
        if stopped.empty?
          @out.puts "dev: no build container running."
        else
          @out.puts "dev: stopped #{stopped.join(", ")} — incremental state kept, dev container up restarts it warm."
        end
      end
    end
  end
end
