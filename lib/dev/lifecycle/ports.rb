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
    # this checkout (dev#192, K1, K5): a `build:` line becomes a
    # ScriptBuilder at the project root, a `package:` line a
    # ScriptPackager, a channel's `run:` a ScriptPublisher, and the
    # built-in packagers are their own ports. The one place the sealed
    # specs are matched, so dev#433's integration builders and dev#422's
    # publishers have one site to join.
    #
    # The project root and the shell are fixed for a checkout and so are
    # constructor-owned; the target is per call.
    class Ports
      extend T::Sig

      # @param project_root [Pathname] where the script forms run
      # @param shell [Shell] the process boundary the script forms and the archive share
      sig { params(project_root: Pathname, shell: Shell).void }
      def initialize(project_root:, shell: Shell.new)
        @project_root = project_root
        @shell = shell
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
      sig { params(channel: Channel).returns(Publisher) }
      def publisher_for(channel)
        spec = channel.publisher
        case spec
        when PublisherSpec::Script then ScriptPublisher.new(command: spec.command, project_root: @project_root, shell: @shell)
        else
          # simplecov:disable — the sealed spec has no other variant yet;
          # T.absurd keeps the static proof.
          T.absurd(spec)
          # simplecov:enable
        end
      end
    end
  end
end
