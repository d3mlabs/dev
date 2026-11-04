# typed: strict
# frozen_string_literal: true

require_relative "command"
require_relative "project_images"

module Dev
  # The composition root's step between parsing dev.yml and assembling the
  # command tree (dev#409): every ProjectCommand's `environment:` reference
  # bound against the lock into its Placement, the tree's shape untouched.
  # Binding here, before CommandRepository#assemble, is what makes an
  # unknown or ambiguous name fail at load — `dev help` included — instead
  # of when the command runs, and what lets the usage printer say where
  # each command runs without a second resolution.
  #
  # The binding itself is ProjectImages#bind (reference → placement); this
  # class only walks the parsed tree with the path each message names.
  class PlacementBinder
    extend T::Sig

    # A node that is neither a ProjectCommand nor a CommandGroup reached
    # the binder. The parser emits only those two, so this is a wiring bug.
    class NotAProjectNodeError < StandardError; end

    # @param images [Dev::ProjectImages] the lock's images, the binding's
    #   other half
    sig { params(images: ProjectImages).void }
    def initialize(images:)
      @images = images
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
  end
end
