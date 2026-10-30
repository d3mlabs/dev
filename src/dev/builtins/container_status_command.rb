# typed: strict
# frozen_string_literal: true

require "dev/builtins/container_command"
require "dev/environment_image"
require "dev/project_images"

module Dev
  module Builtins
    # `dev container status` — where this checkout stands against each of
    # its images and their containers, and what `dev container up` would do
    # about it: one block per image, blank-line separated. A pure report:
    # the image is probed locally and in the registry, never pulled or
    # built; containers are listed, never started. A pinned image (dev#277)
    # is also described — its floor by digest and its platform — and its
    # registry is probed from inside a login session (dev#313), so a private
    # registry answers truthfully; a host without a credential sees the
    # registry half as unknown, not absent.
    class ContainerStatusCommand < ContainerCommand
      extend T::Sig

      sig { override.returns(String) }
      def desc = "Report each build image's state and its container's"

      # @param args [Array<String>] unused
      # @param context [ExecutionContext] the project
      # @return [void]
      sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
      def call(args:, context:)
        project = context.project!
        project.project_images.pinned.each_with_index do |image, index|
          @out.puts if index.positive?
          report(image, project)
        end
      end

      private

      # One image's block.
      #
      # @param image [EnvironmentImage]
      # @param project [ProjectContext]
      # @return [void]
      sig { params(image: EnvironmentImage, project: ProjectContext).void }
      def report(image, project)
        status = client.service_status(image.ref, project.root, registry: image.registry_host)

        @out.puts "image: #{image.name} — #{status.image_tag} — #{image_state(status)}"
        @out.puts "floor: #{image.floor_ref}"
        @out.puts "platform: #{image.platform}"
        current, others = status.containers.partition { |container| container.name == status.current_container_name }
        if image.persist
          @out.puts "container: #{persisted_state(current.first)}"
          others.each do |container|
            @out.puts "stale: #{container.name} — #{running_word(container)} (dev container up removes it)"
          end
        else
          @out.puts "container: not persisted (persist is off); #{in_flight(status.containers)}"
        end
      end

      # @param status [Dev::BuildContainer::ServiceStatus]
      # @return [String]
      sig { params(status: Dev::BuildContainer::ServiceStatus).returns(String) }
      def image_state(status)
        case [status.local_image, status.in_registry]
        when [true, true] then "local, in registry"
        when [true, false] then "local, not in registry"
        when [true, nil] then "local, registry unknown (gh auth login)"
        when [false, true] then "in registry, not local (dev container up pulls it)"
        when [false, nil] then "not local, registry unknown (gh auth login)"
        else "not built (dev container up builds it)"
        end
      end

      # @param current [Dev::BuildContainer::ServiceContainer, nil] the current tag's container
      # @return [String]
      sig { params(current: T.nilable(Dev::BuildContainer::ServiceContainer)).returns(String) }
      def persisted_state(current)
        return "none (dev container up creates it)" if current.nil?

        state = current.running ? "running" : "stopped"
        warm = current.running ? "" : " (dev container up restarts it warm)"
        mounted = current.prefix_volume
        return "#{current.name} — #{state}#{warm}" if mounted.nil?
        return "#{current.name} — #{state}, prefix #{mounted}#{warm}" if mounted == client.prefix_volume

        "#{current.name} — #{state}, prefix #{mounted} — not this user's, #{client.prefix_volume} (dev container up recreates it)"
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
