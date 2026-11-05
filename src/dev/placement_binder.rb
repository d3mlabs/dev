# typed: strict
# frozen_string_literal: true

require "dev/lifecycle"
require "dev/platform"
require_relative "command"
require_relative "project_images"
require_relative "target_placement"

module Dev
  # The composition root's step between parsing dev.yml and assembling the
  # command tree (dev#409): every `environment:` reference bound against
  # the lock into its Placement — each ProjectCommand's, the tree's shape
  # untouched (#bind), each target's, one per platform it declares
  # (#bind_targets, dev#192 K8), and each channel's protocol
  # (#bind_channels, K5). Binding here, before
  # CommandRepository#assemble, is what makes an unknown or ambiguous name
  # fail at load — `dev help` included — instead of when the command runs,
  # and what lets the usage printer say where each command runs without a
  # second resolution.
  #
  # A target's binding carries one check a command's does not: capability
  # against placement. The environment a build runs in must produce the
  # build's platform — an image through the `target_platforms` its block
  # declared, the host for the platform this machine is. The image half is
  # declaration against declaration, so it is refused here, at load, with
  # the fix named: a win64 build pointed at an image without msvc-wine
  # fails before any build, not minutes into one. The host half depends on
  # which machine loads the dev.yml, so it is not a load-time refusal — it
  # rides the TargetPlacement for the verb that asks. Nothing is inferred:
  # dev never searches the pins for an image that could do it.
  #
  # The binding itself is ProjectImages#bind (reference → placement); this
  # class only walks the parsed tree and the targets with the path or name
  # each message carries.
  class PlacementBinder
    extend T::Sig

    # A node that is neither a ProjectCommand nor a CommandGroup reached
    # the binder. The parser emits only those two, so this is a wiring bug.
    class NotAProjectNodeError < StandardError; end

    # A build's environment is an image whose block does not list the
    # build's platform in `target_platforms`.
    class ImageDoesNotProduceError < ArgumentError; end

    # @param images [Dev::ProjectImages] the lock's images, the binding's
    #   other half
    # @param host_os [String] this machine's OS (Dev::Platform.os) — what
    #   `environment: host` produces, via Lifecycle::Platform.for_host_os
    sig { params(images: ProjectImages, host_os: String).void }
    def initialize(images:, host_os: Platform.os)
      @images = images
      @host_platform = T.let(Lifecycle::Platform.for_host_os(host_os), Lifecycle::Platform)
    end

    # Bind every runnable node of the parsed tree, in declaration order.
    #
    # @param commands [Hash{String => ProjectNode}] the parsed dev.yml tree
    # @return [Hash{String => ProjectNode}] the same tree, every
    #   ProjectCommand carrying its Placement
    # @raise [ProjectImages::UnknownImageError] a command names an image the lock does not pin
    # @raise [ProjectImages::AmbiguousEnvironmentImageError] a command names none among several
    sig { params(commands: T::Hash[String, ProjectNode]).returns(T::Hash[String, ProjectNode]) }
    def bind(commands)
      commands.to_h { |name, node| [name, bind_node(node, [name])] }
    end

    # Bind every target's environment, one placement per declared platform
    # (one, under nil, for a target with none), each image checked to
    # produce its platform. In declaration order.
    #
    # @param targets [Hash{String => Lifecycle::Target}] the parsed `targets:`
    # @return [Hash{String => TargetPlacement}]
    # @raise [ProjectImages::UnknownImageError] a target names an image the lock does not pin
    # @raise [ProjectImages::AmbiguousEnvironmentImageError] a target names none among several
    # @raise [ImageDoesNotProduceError] a build's image does not produce its platform
    sig { params(targets: T::Hash[String, Lifecycle::Target]).returns(T::Hash[String, TargetPlacement]) }
    def bind_targets(targets)
      targets.to_h { |name, target| [name, bind_target(target)] }
    end

    # Bind every channel's protocol environment — a script channel's
    # `run:` is placed as a command's body is (dev#192, K5); an
    # integration's publisher is dev's own code and runs where dev runs,
    # so it is placed on the host without a reference to bind (dev#422).
    # In declaration order.
    #
    # @param channels [Hash{String => Lifecycle::Channel}] the parsed channels
    # @return [Hash{String => Placement}] by channel name
    # @raise [ProjectImages::UnknownImageError] a channel names an image the lock does not pin
    # @raise [ProjectImages::AmbiguousEnvironmentImageError] a channel names none among several
    sig { params(channels: T::Hash[String, Lifecycle::Channel]).returns(T::Hash[String, Placement]) }
    def bind_channels(channels)
      channels.to_h do |name, channel|
        spec = channel.publisher
        placement = case spec
        when Lifecycle::PublisherSpec::Script then @images.bind(spec.environment, subject: "deploy #{name}")
        when Lifecycle::PublisherSpec::Integration then Placement::Host.new
        else
          # simplecov:disable — the sealed spec has no other variant;
          # T.absurd keeps the static proof.
          T.absurd(spec)
          # simplecov:enable
        end
        [name, placement]
      end
    end

    private

    # @param node [Command] a parsed project node
    # @param path [Array<String>] its path from the root, for messages
    # @return [ProjectNode]
    # @raise [NotAProjectNodeError]
    sig { params(node: Command, path: T::Array[String]).returns(ProjectNode) }
    def bind_node(node, path)
      children = node.children.to_h { |name, child| [name, T.let(bind_node(child, path + [name]), Command)] }
      case node
      when ProjectCommand
        node.with_placement(@images.bind(node.environment, subject: path.join(" "))).with_children(children)
      when CommandGroup
        CommandGroup.new(path: node.path, desc: node.desc, category: node.category, children:, hidden: node.hidden?)
      else
        raise NotAProjectNodeError, "command '#{path.join(" ")}': a #{node.class.name} is not a parsed project node"
      end
    end

    # @param target [Lifecycle::Target]
    # @return [TargetPlacement]
    # @raise [ImageDoesNotProduceError]
    sig { params(target: Lifecycle::Target).returns(TargetPlacement) }
    def bind_target(target)
      platform_axis = target.platforms? ? target.platforms : [nil]
      placements = platform_axis.to_h do |platform|
        subject = [target.name, platform&.serialize].compact.join("-")
        placement = @images.bind(target.environment_for(platform), subject:)
        assert_image_produces!(placement, platform, subject:) if platform && placement.is_a?(Placement::Image)
        [platform, placement]
      end
      TargetPlacement.new(target:, placements:, host_platform: @host_platform)
    end

    # The image half of the capability check. A platform-less build has
    # nothing to check and builds in its environment as any command would.
    #
    # @param placement [Placement::Image] where builds on +platform+ run
    # @param platform [Lifecycle::Platform] the builds' platform
    # @param subject [String] `<target>-<platform>`, for the message
    # @return [void]
    # @raise [ImageDoesNotProduceError] naming the fix
    sig { params(placement: Placement::Image, platform: Lifecycle::Platform, subject: String).void }
    def assert_image_produces!(placement, platform, subject:)
      return if placement.image.produces?(platform)

      raise ImageDoesNotProduceError,
        "`#{subject}` builds in #{placement.name}, which does not produce #{platform}; " \
          "add `target_platforms :#{platform}` to its image block in dependencies.rb (then `dev deps update`) " \
          "or name another environment"
    end
  end
end
