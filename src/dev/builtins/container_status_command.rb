# typed: strict
# frozen_string_literal: true

require "dev/builtins/container_command"

module Dev
  module Builtins
    # `dev container status` — where this checkout stands against its image
    # and container, and what `dev container up` would do about it. A pure
    # report: the image is probed locally and in the registry, never pulled
    # or built; containers are listed, never started.
    class ContainerStatusCommand < ContainerCommand
      extend T::Sig

      sig { override.returns(String) }
      def desc = "Report this checkout's build image and container state"

      # @param args [Array<String>] unused
      # @param context [ExecutionContext] the project
      # @return [void]
      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        cfg = config(context)
        root = context.project!.root
        status = client.service_status(BuildContainer.image_with_tag(cfg, project_root: root), root)

        @out.puts "image: #{status.image_tag} — #{image_state(status)}"
        current, others = status.containers.partition { |container| container.name == status.current_container_name }
        if cfg.persist
          @out.puts "container: #{persisted_state(current.first)}"
          others.each do |container|
            @out.puts "stale: #{container.name} — #{running_word(container)} (dev container up removes it)"
          end
        else
          @out.puts "container: not persisted (build.container.persist is off); #{in_flight(status.containers)}"
        end
      end

      private

      # @param status [Dev::BuildContainer::ServiceStatus]
      # @return [String]
      sig { params(status: Dev::BuildContainer::ServiceStatus).returns(String) }
      def image_state(status)
        case [status.local_image, status.in_registry]
        when [true, true] then "local, in registry"
        when [true, false] then "local, not in registry"
        when [false, true] then "in registry, not local (dev container up pulls it)"
        else "not built (dev container up builds it)"
        end
      end

      # @param current [Dev::BuildContainer::ServiceContainer, nil] the current tag's container
      # @return [String]
      sig { params(current: T.nilable(Dev::BuildContainer::ServiceContainer)).returns(String) }
      def persisted_state(current)
        return "none (dev container up creates it)" if current.nil?
        return "#{current.name} — running" if current.running

        "#{current.name} — stopped (dev container up restarts it warm)"
      end

      # @param containers [Array<Dev::BuildContainer::ServiceContainer>]
      # @return [String]
      sig { params(containers: T::Array[Dev::BuildContainer::ServiceContainer]).returns(String) }
      def in_flight(containers)
        running = containers.select(&:running).map(&:name)
        running.empty? ? "none in flight" : "in flight: #{running.join(", ")}"
      end

      # @param container [Dev::BuildContainer::ServiceContainer]
      # @return [String]
      sig { params(container: Dev::BuildContainer::ServiceContainer).returns(String) }
      def running_word(container)
        container.running ? "running" : "stopped"
      end
    end
  end
end
