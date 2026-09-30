# typed: strict
# frozen_string_literal: true

require_relative "command"

module Dev
  # Assembles the command tree a project exposes: the builtin nodes the
  # composition root gated into existence (as the root node's children),
  # the project nodes parsed from dev.yml, and — where a project node
  # occupies a builtin's name — their merge (OverriddenCommand for run on
  # builtin body; children merge child by child). Data in, never a path,
  # never a parse. Resolution walks the assembled tree along argv, from
  # the root.
  #
  # Onion rule: CommandService is the only production consumer, and
  # construction is confined to the composition root.
  class CommandRepository
    extend T::Sig

    class CommandNotFoundError < StandardError; end

    # A project node landed on a builtin-side node that is neither a
    # BuiltinCommand nor a CommandGroup — nothing to compose an override
    # from. Builtin trees hold only those two shapes, so reaching this is a
    # dev wiring bug.
    class UnoverridableCommandError < StandardError; end

    # Where argv landed in the tree: the node, the path that reached it,
    # and the tokens left over for it.
    class Resolution < T::Struct
      const :command, Command
      const :path, T::Array[String]
      const :args, T::Array[String]
    end

    # The assembled tree: the root the composition root declared, its
    # children merged with the project's.
    sig { returns(CommandGroup) }
    attr_reader :root

    # @param root [CommandGroup] the builtin tree for this project as the
    #   root node (see CommandGroup.root), children in listing order
    # @param project_commands [Hash{String => ProjectNode}] the parsed
    #   dev.yml tree, in declaration order
    sig do
      params(
        root: CommandGroup,
        project_commands: T::Hash[String, ProjectNode],
      ).void
    end
    def initialize(root:, project_commands:)
      @root = T.let(
        CommandGroup.new(
          path: [],
          desc: root.desc,
          category: root.category,
          children: assemble(root.children, project_commands, []),
        ),
        CommandGroup,
      )
    end

    # Walk the tree along argv from the root: descend while the next token
    # names a child of the current node; the first token that doesn't is
    # where the args begin. A group cannot take args — it only prints
    # usage — so a leftover token there is an unknown subcommand (at the
    # root: an unknown command). Empty argv resolves to the root.
    #
    # @param argv [Array<String>] the full argv, command path first
    # @return [Resolution]
    # @raise [CommandNotFoundError] for an unknown top-level name or an
    #   unknown child of a group
    sig { params(argv: T::Array[String]).returns(Resolution) }
    def resolve(argv)
      node = T.let(@root, Command)
      path = T.let([], T::Array[String])
      rest = argv.dup
      loop do
        token = rest.first
        child = token && node.children[token]
        if child.nil?
          if node.is_a?(CommandGroup) && token
            raise CommandNotFoundError, "Command '#{(path + [token]).join(" ")}' not found"
          end
          break
        end
        node = child
        path << T.must(rest.shift)
      end
      Resolution.new(command: node, path: path, args: rest)
    end

    private

    # Merge one level of builtin and project nodes into the resolved view.
    # Builtins keep their listing position (a project node on a builtin's
    # name merges in place); project-only nodes follow in declaration
    # order. Hash keys are unique, so a duplicate declaration is
    # unrepresentable.
    #
    # @param builtins [Hash{String => Command}]
    # @param project_nodes [Hash{String => Command}] parsed project nodes
    #   (typed as Command below the top level, since that is what
    #   `children` carries)
    # @param path [Array<String>] the path to this level
    # @return [Hash{String => Command}]
    sig do
      params(
        builtins: T::Hash[String, Command],
        project_nodes: T::Hash[String, Command],
        path: T::Array[String],
      ).returns(T::Hash[String, Command])
    end
    def assemble(builtins, project_nodes, path)
      commands = T.let(builtins.dup, T::Hash[String, Command])
      project_nodes.each do |name, project_node|
        builtin = builtins[name]
        commands[name] = builtin ? merge(builtin, project_node, path + [name]) : project_node
      end
      commands
    end

    # A project node on a builtin's name. Children always merge child by
    # child (a project child on a builtin child's name recurses here). The
    # bodies compose by shape:
    #
    # - project run on builtin body → OverriddenCommand (the classic
    #   override: builtin first, then the project's run)
    # - project run on builtin group → the project run, heading the merged
    #   children (nothing on the builtin side to run first)
    # - project group on builtin body → the builtin, heading the merged
    #   children (the project only added subcommands)
    # - project group on builtin group → a group over the merged children,
    #   with the project's desc and visibility, the builtin's category
    #
    # @param builtin [Command]
    # @param project [Command] a parsed project node
    # @param path [Array<String>]
    # @return [Command]
    # @raise [UnoverridableCommandError] when the builtin side is not a
    #   BuiltinCommand or CommandGroup, or the project side is not a
    #   ProjectNode (both wiring bugs: the parser emits only ProjectNodes,
    #   the composition roots only builtins and groups)
    sig { params(builtin: Command, project: Command, path: T::Array[String]).returns(Command) }
    def merge(builtin, project, path)
      unless builtin.is_a?(BuiltinCommand) || builtin.is_a?(CommandGroup)
        raise UnoverridableCommandError,
          "command '#{path.join(" ")}': a project command cannot override a #{builtin.class.name}"
      end
      unless project.is_a?(ProjectCommand) || project.is_a?(CommandGroup)
        raise UnoverridableCommandError,
          "command '#{path.join(" ")}': a #{project.class.name} is not a parsed project node"
      end

      children = assemble(builtin.children, project.children, path)
      case project
      when ProjectCommand
        builtin.is_a?(BuiltinCommand) ? OverriddenCommand.new(builtin:, project:, children:) : project.with_children(children)
      when CommandGroup
        if builtin.is_a?(BuiltinCommand)
          builtin.with_children(children)
        else
          CommandGroup.new(path:, desc: project.desc, category: builtin.category, children:, hidden: project.hidden?)
        end
      else
        # simplecov:disable — the guard above closes the union; T.absurd
        # keeps the static proof.
        T.absurd(project)
        # simplecov:enable
      end
    end
  end
end
