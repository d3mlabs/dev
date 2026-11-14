# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "archive"
require_relative "as_is_packager"
require_relative "builder"
require_relative "builder_spec"
require_relative "channel"
require_relative "none_packager"
require_relative "packager"
require_relative "packager_spec"
require_relative "publisher"
require_relative "publisher_spec"
require_relative "script_builder"
require_relative "script_packager"
require_relative "script_publisher"
require_relative "shell"
require_relative "target"

module Dev
  module Lifecycle
    # Turns a target's and a channel's declarations into their ports for
    # this checkout: a `build:` line becomes a ScriptBuilder, a `package:`
    # line a ScriptPackager, a channel's `run:` a ScriptPublisher, a channel
    # naming an integration the publisher the lock contributed under that
    # name. The one place the sealed specs are matched.
    #
    # The project root, the shell and the lock's publishers are fixed for
    # a checkout and so are constructor-owned; the target is per call.
    class Ports
      extend T::Sig

      # A channel names an integration publisher the table does not hold.
      # The composition root binds every channel's reference against the
      # lock before the tree exists (ChannelBinder), so reaching this is a
      # dev wiring bug, not a dev.yml error.
      class UnknownPublisherError < StandardError; end

      # @param project_root [Pathname] where the script forms run
      # @param shell [Shell] the process boundary the script forms and the archive share
      # @param publishers [Hash{String => Publisher}] the publishers the
      #   lock contributes, by channel name
      sig { params(project_root: Pathname, shell: Shell, publishers: T::Hash[String, Publisher]).void }
      def initialize(project_root:, shell: Shell.new, publishers: {})
        @project_root = project_root
        @shell = shell
        @publishers = publishers
      end

      # The target's builder, or nil when it declares nothing to compile.
      #
      # @param target [Target]
      # @return [Builder, nil]
      sig { params(target: Target).returns(T.nilable(Builder)) }
      def builder_for(target)
        spec = target.builder
        case spec
        when nil then nil
        when BuilderSpec::Script then ScriptBuilder.new(command: spec.command, project_root: @project_root, shell: @shell)
        else
          # simplecov:disable — the sealed spec has no other variant yet;
          # T.absurd keeps the static proof.
          T.absurd(spec)
          # simplecov:enable
        end
      end

      # The target's packager — a NonePackager for `packager: none`, which
      # a caller checks with Target#packageable? before reaching for it.
      #
      # @param target [Target]
      # @return [Packager]
      sig { params(target: Target).returns(Packager) }
      def packager_for(target)
        spec = target.packager
        case spec
        when PackagerSpec::Script then ScriptPackager.new(command: spec.command, project_root: @project_root, shell: @shell)
        when PackagerSpec::Archive then Archive.new(form: spec.form, shell: @shell)
        when PackagerSpec::AsIs then AsIsPackager.new
        when PackagerSpec::None then NonePackager.new
        else
          # simplecov:disable — the sealed spec has no other variant yet;
          # T.absurd keeps the static proof.
          T.absurd(spec)
          # simplecov:enable
        end
      end

      # The channel's protocol.
      #
      # @param channel [Channel]
      # @return [Publisher]
      # @raise [UnknownPublisherError]
      sig { params(channel: Channel).returns(Publisher) }
      def publisher_for(channel)
        spec = channel.publisher
        case spec
        when PublisherSpec::Script then ScriptPublisher.new(command: spec.command, project_root: @project_root, shell: @shell)
        when PublisherSpec::Integration
          @publishers.fetch(spec.name) do
            contributed = @publishers.empty? ? "none" : @publishers.keys.join(", ")
            raise UnknownPublisherError,
              "channel '#{channel}' names the #{spec.name} publisher, which the lock did not contribute " \
                "(it contributes: #{contributed})"
          end
        else
          # simplecov:disable — the sealed spec has no other variant;
          # T.absurd keeps the static proof.
          T.absurd(spec)
          # simplecov:enable
        end
      end
    end
  end
end
