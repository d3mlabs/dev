# typed: strict
# frozen_string_literal: true

require_relative "command"
require_relative "project_command_group"

module Dev
  # Assembles the command tree a project exposes: the builtin nodes the
  # composition root gated into existence, the project nodes parsed from
  # dev.yml, and — where a project node occupies a builtin's name — their
  # merge (OverriddenCommand for leaf on leaf; child-by-child for groups).
  # Data in, never a path, never a parse. Resolution walks the assembled
  # tree along argv.
  #
  # Onion rule: CommandService is the only production consumer, and
  # construction is confined to the composition root.
  class CommandRepository
    extend T::Sig

    class CommandNotFoundError < StandardError; end

    # A project node landed on a resolved command that is neither a builtin
    # leaf nor a group — nothing to compose an override from. Builtin trees
    # hold only those two shapes, so reaching this is a dev wiring bug.
    class UnoverridableCommandError < StandardError; end

    # Where argv landed in the tree: the node, the path that reached it,
    # and the tokens left over for it.
    class Resolution < T::Struct
      const :command, Command
      const :path, T::Array[String]
      const :args, T::Array[String]
    end

    # @param builtins [Hash{String => Command}] the builtin tree for this
    #   project, in listing order (leaves and CommandGroups)
    # @param project_commands [Hash{String => ProjectNode}] the parsed
    #   dev.yml tree, in declaration order
    sig do
      params(
        builtins: T::Hash[String, Command],
        project_commands: T::Hash[String, ProjectNode],
      ).void
    end
    def initialize(builtins:, project_commands:)
      @commands = T.let(assemble(builtins, project_commands, []).freeze, T::Hash[String, Command])
    end

    # Look up a top-level command by name.
    #
    # @param name [String] command name
    # @return [Command]
    # @raise [CommandNotFoundError] if no command exists with that name
    sig { params(name: String).returns(Command) }
    def fetch(name)
      @commands.fetch(name) do
        raise CommandNotFoundError, "Command '#{name}' not found"
      end
    end

    # Walk the tree along argv: descend while the next token names a child
    # of the current group; stop at a leaf, or at a group whose next token
    # is not a child (the rest is that node's args). A pure group cannot
    # take args — it only prints usage — so leftover tokens there are an
    # unknown subcommand.
    #
    # @param argv [Array<String>] the full argv, command path first
    # @return [Resolution]
    # @raise [CommandNotFoundError] for an unknown top-level name, an unknown
    #   child of a pure group, or empty argv
    sig { params(argv: T::Array[String]).returns(Resolution) }
    def resolve(argv)
      first = argv.first
      raise CommandNotFoundError, "no command given" if first.nil?

      node = T.let(fetch(first), Command)
      path = [first]
      rest = argv.drop(1)
      loop do
        break unless node.is_a?(CommandGroup)

        token = rest.first
        child = token && node.children[token]
        if child.nil?
          if node.own.nil? && token
            raise CommandNotFoundError, "Command '#{(path + [token]).join(" ")}' not found"
          end
          break
        end
        node = child
        path << T.must(rest.shift)
      end
      Resolution.new(command: node, path: path, args: rest)
    end

    # The top-level commands usage advertises, in listing order (hidden ones
    # stay callable but unlisted).
    #
    # @return [Hash{String => Command}]
    sig { returns(T::Hash[String, Command]) }
    def visible_commands
      @commands.reject { |_name, command| command.hidden? }
    end

    private

    # Merge one level of builtin and project nodes into the resolved view.
    # Builtins keep their listing position (a project node on a builtin's
    # name merges in place); project-only nodes follow in declaration
    # order. Hash keys are unique, so a duplicate declaration is
    # unrepresentable.
    #
    # @param builtins [Hash{String => Command}]
    # @param project_nodes [Hash{String => ProjectNode}]
    # @param path [Array<String>] the path to this level
    # @return [Hash{String => Command}]
    sig do
      params(
        builtins: T::Hash[String, Command],
        project_nodes: T::Hash[String, ProjectNode],
        path: T::Array[String],
      ).returns(T::Hash[String, Command])
    end
    def assemble(builtins, project_nodes, path)
      commands = T.let(builtins.dup, T::Hash[String, Command])
      project_nodes.each do |name, project_node|
        builtin = builtins[name]
        commands[name] = builtin ? merge(builtin, project_node, path + [name]) : resolve_project(project_node, path + [name])
      end
      commands
    end

    # A project node with no builtin on its name: a leaf stands as itself; a
    # group becomes a CommandGroup over its resolved children.
    #
    # @param node [ProjectNode]
    # @param path [Array<String>]
    # @return [Command]
    sig { params(node: ProjectNode, path: T::Array[String]).returns(Command) }
    def resolve_project(node, path)
      case node
      when ProjectCommand then node
      when ProjectCommandGroup
        CommandGroup.new(
          path: path,
          desc: node.desc,
          category: Command::Category::Project,
          children: assemble({}, node.children, path),
          own: node.own,
          hidden: node.hidden?,
        )
      else
        # simplecov:disable — ProjectNode is a closed union; T.absurd keeps
        # the static exhaustiveness proof.
        T.absurd(node)
        # simplecov:enable
      end
    end

    # A project node on a builtin's name. Leaf on leaf is the classic
    # override. Any group involvement yields a CommandGroup: children merge
    # recursively, own leaves merge like a slot (both → override, one →
    # that one). The override owns the slot's desc and visibility; the slot
    # keeps its category.
    #
    # @param builtin [Command]
    # @param project [ProjectNode]
    # @param path [Array<String>]
    # @return [Command]
    # @raise [UnoverridableCommandError]
    sig { params(builtin: Command, project: ProjectNode, path: T::Array[String]).returns(Command) }
    def merge(builtin, project, path)
      if builtin.is_a?(BuiltinCommand) && project.is_a?(ProjectCommand)
        return OverriddenCommand.new(builtin:, project:)
      end

      builtin_children = builtin.is_a?(CommandGroup) ? builtin.children : {}
      builtin_own = builtin.is_a?(CommandGroup) ? builtin.own : builtin
      project_children = project.is_a?(ProjectCommandGroup) ? project.children : {}
      project_own = project.is_a?(ProjectCommandGroup) ? project.own : project
      CommandGroup.new(
        path: path,
        desc: project.desc,
        category: builtin.category,
        children: assemble(builtin_children, project_children, path),
        own: project_own ? merge_own(builtin_own, project_own, path) : builtin_own,
        hidden: project.hidden?,
      )
    end

    # The own slot of a merged group: the project leaf alone when the
    # builtin side has none, else their override composition.
    #
    # @param builtin_own [Command, nil]
    # @param project_own [ProjectCommand]
    # @param path [Array<String>]
    # @return [Command]
    # @raise [UnoverridableCommandError] when the builtin side's own leaf is
    #   not a builtin (a wiring bug)
    sig { params(builtin_own: T.nilable(Command), project_own: ProjectCommand, path: T::Array[String]).returns(Command) }
    def merge_own(builtin_own, project_own, path)
      case builtin_own
      when nil then project_own
      when BuiltinCommand then OverriddenCommand.new(builtin: builtin_own, project: project_own)
      else
        raise UnoverridableCommandError,
          "command '#{path.join(" ")}': a project run cannot override a #{builtin_own.class.name}"
      end
    end
  end
end
