# typed: strict
# frozen_string_literal: true

require_relative "execution_context"

module Dev
  # Sealed command hierarchy. A command is one of exactly four shapes:
  #
  # - BuiltinCommand: a Ruby body dev ships (an abstract class, the
  #   hierarchy's one declared open edge; subclasses live under
  #   src/dev/builtins/)
  # - ProjectCommand: pure data parsed from a dev.yml `commands:` entry
  # - OverriddenCommand: a project command occupying a builtin's slot (the
  #   builtin runs first, like a hardcoded super())
  # - CommandGroup: a command with nothing to run — invoked bare it prints
  #   its usage; it exists to hold children
  #
  # Every command is a node of the command tree: each has `children`
  # (usually none). Resolution descends while the next argv token names a
  # child, so `dev deps path` reaches the leaf and `dev test --fast` runs a
  # `test` that happens to have children, forwarding the flag. The shapes
  # differ only in what the bare invocation does.
  #
  # Sealing makes a fifth variant unrepresentable: CommandExecutor
  # dispatches exhaustively over these four (case + T.absurd), and Sorbet
  # requires a sealed module's direct heirs beside it, which is why the
  # hierarchy shares this file.
  #
  # Command is a module rather than a class deliberately. A sealed class's
  # runtime `inherited` hook rides down the singleton chain to every
  # descendant, so builtins subclassing an abstract BuiltinCommand class
  # raise at definition time unless sorbet-runtime internals are faked open
  # (the ivar pokes this file used to carry). A sealed module's `included`
  # hook fires only for its direct includers — the four heirs below —
  # because `include` never transfers singleton methods, so subclassing
  # BuiltinCommand is an honest open edge with nothing to suppress. Descent
  # is closed everywhere it is not explicitly declared: the data shapes are
  # final!.
  module Command
    extend T::Sig
    extend T::Helpers
    # Every includer is an Object, so this changes nothing at runtime; it
    # tells Sorbet that `is_a?`/`nil?` exist on a value typed as the
    # interface, which the tree code narrows on.
    include Kernel
    abstract!
    sealed!

    # The named subcommands, in listing order. Empty for most commands.
    sig { abstract.returns(T::Hash[String, Command]) }
    def children; end

    # The usage sections `dev --help` renders. Every command declares its
    # group explicitly (the trait is abstract, not defaulted) so nothing
    # lands in a section silently.
    class Category < T::Enum
      enums do
        # Environment provisioning and dependency state (up, check, ...).
        Lifecycle = new
        # Day-to-day development tooling (cd, plan, help, ...).
        Workflow = new
        # Commands the project defines in dev.yml.
        Project = new
      end
    end

    sig { abstract.returns(String) }
    def desc; end

    # The usage section this command lists under.
    sig { abstract.returns(Category) }
    def category; end

    # Whether this command is callable but omitted from `dev`/`dev --help`
    # usage. Used for internal plumbing (e.g. build primitives) a project
    # keeps invocable without advertising it. Visible by default.
    sig { overridable.returns(T::Boolean) }
    def hidden? = false

    # Whether the staleness guard skips this command. Exempt commands ARE
    # the staleness remediation (or its explicit check) — nagging before
    # them would block the very fix being run.
    sig { overridable.returns(T::Boolean) }
    def staleness_exempt? = false

    # Whether a fully-successful run records the installed stamp
    # (DependencyService#lock!). Stamping commands must run their process
    # halves spawn-and-wait — exec-replace would make the stamp
    # unreachable (#85); CommandExecutor derives wait-vs-exec from this.
    sig { overridable.returns(T::Boolean) }
    def stamps? = false

    # The argument candidates a command offers to shell completion when the
    # walk down the tree ends on it: `words` are the ones typed after its
    # own name (flags included), the result is printed as-is — in *this*
    # order, which is the command's to decide (#211: order can carry
    # meaning). Must work offline and never raise into the shell. Nothing
    # by default; a leaf that knows its arguments overrides.
    #
    # @param words [Array<String>] the words typed after this command so far
    # @return [Array<String>]
    sig { overridable.params(words: T::Array[String]).returns(T::Array[String]) }
    def completions(words)
      _ = words
      []
    end
  end

  # Built-in command that executes Ruby code: the hierarchy's declared open
  # edge. Subclasses live under src/dev/builtins/, one class per builtin,
  # with collaborators injected through their constructors; per-call values
  # arrive through #call. Test fakes subclass it the same way.
  #
  # A class rather than a module because Sorbet flattens module mixins:
  # were this a module, every includer would gain sealed Command as a
  # direct mixin in the symbol table and fail the same-file check
  # statically. A superclass edge is not flattened, so subclasses inherit
  # Command's membership without re-including it — legal statically, and
  # invisible to the seal's runtime hooks.
  class BuiltinCommand
    extend T::Sig
    extend T::Helpers
    include Command
    abstract!

    # @param children [Hash{String => Command}] subcommands, when the
    #   builtin heads a subtree (most leaves pass nothing)
    sig { params(children: T::Hash[String, Command]).void }
    def initialize(children: {})
      @children = T.let(children.freeze, T::Hash[String, Command])
    end

    sig { override.returns(T::Hash[String, Command]) }
    attr_reader :children

    # The same builtin heading a different subtree — how a project's
    # `commands:` attach under a builtin's name (the body stays the
    # builtin's; the repository computes the merged children).
    #
    # @param children [Hash{String => Command}]
    # @return [BuiltinCommand] a copy; the receiver is untouched
    sig { params(children: T::Hash[String, Command]).returns(T.self_type) }
    def with_children(children)
      copy = dup
      copy.instance_variable_set(:@children, children.freeze)
      copy
    end

    sig { abstract.params(args: T::Array[String], context: ExecutionContext).void }
    def call(args:, context:); end
  end

  # Project command from a dev.yml `commands:` entry. Pure data: the run
  # string, optional description, repl flag, container opt-out, and the
  # nested `commands:` as children. When build.container is declared,
  # commands run inside the container by default unless container: false.
  class ProjectCommand
    extend T::Sig
    extend T::Helpers
    include Command
    final!

    sig(:final) { returns(String) }
    attr_reader :run

    sig(:final) { override.returns(String) }
    attr_reader :desc

    sig(:final) { returns(T::Boolean) }
    attr_reader :repl

    # Whether this command should run inside the build container (when one is
    # configured). Defaults to true; set to false via `container: false` in dev.yml.
    sig(:final) { returns(T::Boolean) }
    attr_reader :container

    sig(:final) { override.returns(T::Hash[String, Command]) }
    attr_reader :children

    sig(:final) do
      params(
        run: String,
        desc: String,
        repl: T::Boolean,
        container: T::Boolean,
        hidden: T::Boolean,
        children: T::Hash[String, Command],
      ).void
    end
    def initialize(run:, desc: "(no description)", repl: false, container: true, hidden: false, children: {})
      super()
      @run = run
      @desc = desc
      @repl = repl
      @container = container
      @hidden = hidden
      @children = T.let(children.freeze, T::Hash[String, Command])
    end

    sig(:final) { override.returns(T::Boolean) }
    def hidden? = @hidden

    sig(:final) { override.returns(Category) }
    def category = Category::Project

    # The same command heading a different subtree (the repository's merge
    # of a project `run:` over a builtin group's children).
    #
    # @param children [Hash{String => Command}]
    # @return [ProjectCommand]
    sig(:final) { params(children: T::Hash[String, Command]).returns(ProjectCommand) }
    def with_children(children)
      ProjectCommand.new(run: @run, desc: @desc, repl: @repl, container: @container, hidden: @hidden, children:)
    end

    sig(:final) { params(other: Object).returns(T::Boolean) }
    def ==(other)
      return false unless other.is_a?(ProjectCommand)

      @run == other.run && @desc == other.desc && @repl == other.repl &&
        @container == other.container && @hidden == other.hidden? && @children == other.children
    end

    sig(:final) { params(other: Object).returns(T::Boolean) }
    def eql?(other)
      self == other
    end

    sig(:final) { returns(Integer) }
    def hash
      [@run, @desc, @repl, @container, @hidden, @children].hash
    end
  end

  # A project command occupying a builtin's slot. Mirrors OOP virtual
  # dispatch: the override owns the slot, and its implementation calls
  # super() at the top — CommandExecutor runs the builtin body first, then
  # the project command.
  class OverriddenCommand
    extend T::Sig
    extend T::Helpers
    include Command
    final!

    sig(:final) { returns(BuiltinCommand) }
    attr_reader :builtin

    sig(:final) { returns(ProjectCommand) }
    attr_reader :project

    sig(:final) { override.returns(T::Hash[String, Command]) }
    attr_reader :children

    # @param builtin [BuiltinCommand] the slot
    # @param project [ProjectCommand] the override
    # @param children [Hash{String => Command}] the merged subtree; defaults
    #   to the project's children over the builtin's (the repository passes
    #   its recursive merge)
    sig(:final) do
      params(builtin: BuiltinCommand, project: ProjectCommand, children: T::Hash[String, Command]).void
    end
    def initialize(builtin:, project:, children: builtin.children.merge(project.children))
      super()
      @builtin = builtin
      @project = project
      @children = T.let(children.freeze, T::Hash[String, Command])
    end

    # The override owns the slot, so its description wins — a project `up:`
    # shows its own desc in usage, not the generic builtin one.
    sig(:final) { override.returns(String) }
    def desc = @project.desc

    sig(:final) { override.returns(T::Boolean) }
    def hidden? = @project.hidden?

    # Guard and stamp traits belong to the slot, not the override: a project
    # `up:` still is the provisioning command, so it inherits the builtin's
    # exemption and stamping behavior.
    sig(:final) { override.returns(T::Boolean) }
    def staleness_exempt? = @builtin.staleness_exempt?

    sig(:final) { override.returns(T::Boolean) }
    def stamps? = @builtin.stamps?

    # So do the argument completions: the builtin knows its arguments, the
    # project body wrapping it runs after and takes the same ones.
    sig(:final) { override.params(words: T::Array[String]).returns(T::Array[String]) }
    def completions(words) = @builtin.completions(words)

    # The usage section belongs to the slot too: an overriding `up:` still
    # lists under Lifecycle, with the project's description.
    sig(:final) { override.returns(Category) }
    def category = @builtin.category

    # Value equality over the halves and the subtree (builtins compare by
    # identity — they are the wired instances).
    sig(:final) { params(other: Object).returns(T::Boolean) }
    def ==(other)
      return false unless other.is_a?(OverriddenCommand)

      @builtin == other.builtin && @project == other.project && @children == other.children
    end

    sig(:final) { params(other: Object).returns(T::Boolean) }
    def eql?(other)
      self == other
    end

    sig(:final) { returns(Integer) }
    def hash
      [@builtin, @project, @children].hash
    end
  end

  # A command with nothing of its own to run: pure data (children, desc),
  # interpreted by CommandExecutor's group arm as "print this node's
  # usage" — the same way ProjectCommand is data interpreted by
  # ProjectExecutor. Builtin groups are declared in the composition roots;
  # project groups are parsed from a dev.yml entry with `commands:` and no
  # `run:`; a project group on a builtin's name merges child by child in
  # CommandRepository. Immutable, like the data leaves: merging constructs
  # a new node.
  class CommandGroup
    extend T::Sig
    extend T::Helpers
    include Command
    final!

    # A group with no children can never do anything; rejecting it here
    # keeps every resolved node meaningful.
    class EmptyGroupError < ArgumentError; end

    class << self
      extend T::Sig

      # The tree's root: `dev` itself, a group whose children are the
      # top-level commands. Bare `dev` resolves to it and prints its usage;
      # `dev nope` is a leftover token on a group, like any unknown child.
      # It lists nowhere, so its category is never read.
      #
      # @param desc [String] the line the usage prints under the invocation
      # @param children [Hash{String => Command}] the top-level commands
      # @return [CommandGroup]
      sig(:final) { params(desc: String, children: T::Hash[String, Command]).returns(CommandGroup) }
      def root(desc:, children:)
        new(path: [], desc:, category: Command::Category::Workflow, children:)
      end
    end

    # The command path from the root (`["deps"]`, `["test", "unit"]`;
    # empty for the root itself); what the group's usage line renders.
    sig(:final) { returns(T::Array[String]) }
    attr_reader :path

    sig(:final) { override.returns(T::Hash[String, Command]) }
    attr_reader :children

    sig(:final) { override.returns(String) }
    attr_reader :desc

    sig(:final) { override.returns(Category) }
    attr_reader :category

    sig(:final) do
      params(
        path: T::Array[String],
        desc: String,
        category: Category,
        children: T::Hash[String, Command],
        hidden: T::Boolean,
      ).void
    end
    def initialize(path:, desc:, category:, children:, hidden: false)
      super()
      raise EmptyGroupError, "command '#{path.join(" ")}': a group needs children" if children.empty?

      @path = path
      @desc = desc
      @category = category
      @children = T.let(children.freeze, T::Hash[String, Command])
      @hidden = hidden
    end

    sig(:final) { override.returns(T::Boolean) }
    def hidden? = @hidden

    # Usage must work while stale — it is how the children get discovered
    # (same reason as HelpCommand) — and records nothing.
    sig(:final) { override.returns(T::Boolean) }
    def staleness_exempt? = true

    sig(:final) { params(other: Object).returns(T::Boolean) }
    def ==(other)
      return false unless other.is_a?(CommandGroup)

      @path == other.path && @desc == other.desc && @category == other.category &&
        @children == other.children && @hidden == other.hidden?
    end

    sig(:final) { params(other: Object).returns(T::Boolean) }
    def eql?(other)
      self == other
    end

    sig(:final) { returns(Integer) }
    def hash
      [@path, @desc, @category, @children, @hidden].hash
    end
  end

  # What a dev.yml `commands:` entry parses to: a runnable command (with or
  # without children) or a group.
  ProjectNode = T.type_alias { T.any(ProjectCommand, CommandGroup) }
end
