# typed: strict
# frozen_string_literal: true

require "dev/environment_ref"
require_relative "flag"
require_relative "parsed_args"
require_relative "dispatch"
require_relative "execution_context"
require_relative "placement"

module Dev
  module Cli
    # Sealed command hierarchy. A command is one of exactly five shapes:
    #
    # - BuiltinCommand: a Ruby body dev ships (an abstract class, one of the
    #   hierarchy's two declared open edges; subclasses live under
    #   lib/dev/cli/builtins/)
    # - LifecycleCommand: a build-lifecycle verb (build, package, deploy,
    #   release — dev#192) — a Ruby stage around a replaceable seam, run as
    #   before → seam → after (the other open edge)
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
    # Sealing makes a sixth variant unrepresentable: CommandExecutor
    # dispatches exhaustively over these five (case + T.absurd), and Sorbet
    # requires a sealed module's direct heirs beside it, which is why the
    # hierarchy shares this file.
    #
    # Command is a module rather than a class deliberately. A sealed class's
    # runtime `inherited` hook rides down the singleton chain to every
    # descendant, so builtins subclassing an abstract BuiltinCommand class
    # raise at definition time unless sorbet-runtime internals are faked open
    # (the ivar pokes this file used to carry). A sealed module's `included`
    # hook fires only for its direct includers — the five heirs below —
    # because `include` never transfers singleton methods, so subclassing
    # BuiltinCommand or LifecycleCommand is an honest open edge with nothing
    # to suppress. Descent is closed everywhere it is not explicitly
    # declared: the data shapes are final!.
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
          # The build lifecycle's verbs over the project's targets (build,
          # package, deploy, release — dev#192).
          Lifecycle = new
          # Environment provisioning and dependency state (up, deps,
          # container, engine, runner, down).
          Environment = new
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
      def hidden?
        false
      end

      # Whether the staleness guard skips this command. Exempt commands ARE
      # the staleness remediation (or its explicit check) — nagging before
      # them would block the very fix being run.
      sig { overridable.returns(T::Boolean) }
      def staleness_exempt?
        false
      end

      # Whether a fully-successful run records the installed stamp
      # (DependencyService#lock!). Stamping commands must run their process
      # halves spawn-and-wait — exec-replace would make the stamp
      # unreachable (#85); CommandExecutor derives wait-vs-exec from this.
      sig { overridable.returns(T::Boolean) }
      def stamps?
        false
      end

      # The `-`-prefixed arguments this command accepts, each with its arity
      # (Cli::Flag). Cli::FlagVocabulary parses an argv against this list
      # (plus the help flags every node answers to) before the command runs;
      # a flag a command reads but does not declare here is rejected as
      # unknown. Nothing by default: groups and most leaves take none.
      sig { overridable.returns(T::Array[Cli::Flag]) }
      def flags
        []
      end

      # Whether this command's argv is forwarded verbatim — no help-flag
      # interpretation, no vocabulary check, `--` kept. True for the shapes
      # whose argv belongs to someone else: a project `run:` (the script owns
      # its flags, `dev test --help` reaches it), and a builtin whose words are
      # another command's argv (`complete`). Dev-defined nodes keep the
      # default and declare `flags` instead.
      sig { overridable.returns(T::Boolean) }
      def opaque_args?
        false
      end

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
    # edge. Subclasses live under lib/dev/cli/builtins/, one class per builtin,
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

      # The body. `args` arrive parsed against this command's `flags`: read
      # them by name (ParsedArgs#flag?/#value/#values) and the rest as
      # positionals; an opaque command reads its words.
      sig { abstract.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
      def call(args:, context:); end
    end

    # A build-lifecycle verb (dev#192, K1b): dev's stage **around** a
    # replaceable seam — the builder for `build`, the packager for `package`,
    # the channel's protocol for `deploy` — run by LifecycleExecutor as
    # before → seam → after. Not a BuiltinCommand: a builtin is one body; an
    # OverriddenCommand runs the builtin then the project's run with the
    # same argv. A verb needs a step *after* the seam (`package` stamps the
    # manifest, `deploy` records the receipt), so every seam is spawn-and-wait
    # (Lifecycle::Shell; an exec-replace would make `after` unreachable, as
    # dev#85 found for the stamp), a failure in the seam short-circuits
    # `after` (it raises; nothing catches it before the CLI boundary), and
    # the seam never sees argv: `before` **consumes** the flags into the
    # verb's `Env` — the typed form of what the seam runs against, which the
    # script forms spell as `DEV_*` (Lifecycle::ScriptEnv) — and returns the
    # Dispatch outcome: `Run(env)` to run the seam here, `Done` when the
    # dispatch ran the verb on another host (dev#420).
    #
    # The hierarchy's second open edge, a class for the same reason as
    # BuiltinCommand. Subclasses — one per verb, under lib/dev/cli/builtins/ —
    # fix `Env` to their own struct and take their collaborators (the
    # targets' placements, the ports, the store, the DispatchResolver)
    # through the constructor. A project node never lands on a verb's slot:
    # `build`/`package`/`release` admit none, and `deploy`'s channel merge is
    # the repository's third case when the lock contributes channels
    # (dev#422). Always `Category::Lifecycle`.
    class LifecycleCommand
      extend T::Sig
      extend T::Helpers
      extend T::Generic
      include Command
      abstract!

      # What the verb's `before` resolves from the flags and positionals,
      # and what its seam and `after` read instead of argv.
      Env = type_member

      # One thing a verb acts on, as its own usage lists it (dev#192, K2):
      # a build for `build`/`package`, with the placement its target
      # declares for it — the usage printer renders the placement as the
      # environment column, under the host rule — and a note when this
      # machine cannot produce it where it is placed.
      class Subject < T::Struct
        const :name, String
        const :desc, String
        const :placement, T.nilable(Placement), default: nil
        const :note, T.nilable(String), default: nil
      end

      # The section a verb's usage prints beneath its flags: a heading and
      # the subjects, in declaration order.
      class Listing < T::Struct
        const :heading, String
        const :subjects, T::Array[Subject]
      end

      # @param children [Hash{String => Command}] subcommands, when the verb
      #   heads a subtree (`deploy`'s channels)
      sig { params(children: T::Hash[String, Command]).void }
      def initialize(children: {})
        @children = T.let(children.freeze, T::Hash[String, Command])
      end

      sig { override.returns(T::Hash[String, Command]) }
      attr_reader :children

      # The four verbs list together: the section is the shape's, not each
      # verb's to choose.
      sig { override.returns(Category) }
      def category
        Category::Lifecycle
      end

      # What `dev help <verb>` lists beneath the verb's flags — every build
      # the project declares, with its environment on this machine, for
      # `build` and `package`. Nil for a verb with nothing to enumerate.
      #
      # @return [Listing, nil]
      sig { overridable.returns(T.nilable(Listing)) }
      def listing
        nil
      end

      # Where the verb's seam runs when that is one place — a channel's
      # protocol (dev#192, K5) — as the usage printer's environment column
      # and sentence read it, the way a project command's placement is read.
      # Nil for a verb placed per build (`build`, `package`: the listing
      # carries each build's), and for one the composition root could not
      # bind.
      #
      # @return [Placement, nil]
      sig { overridable.returns(T.nilable(Placement)) }
      def placement
        nil
      end

      # Lines the usage prints beneath the verb's description — in its own
      # usage and under its row in its parent's listing — for what a one-line
      # summary cannot carry: a channel's accept set and where its protocol
      # comes from. Nothing by default.
      #
      # @return [Array<String>]
      sig { overridable.returns(T::Array[String]) }
      def details
        []
      end

      # The stage before the seam: consume the flags and positionals into
      # the verb's Env (the build, where its install goes, …), resolve where
      # it runs and dispatch it. The seam sees nothing of `args`.
      #
      # @param args [Cli::ParsedArgs] parsed against this command's `flags`
      # @param context [ExecutionContext]
      # @return [Dispatch::Outcome] Run(env) to run the seam here; Done when
      #   the dispatch ran the verb elsewhere
      sig { abstract.params(args: Cli::ParsedArgs, context: ExecutionContext).returns(Dispatch::Outcome[Env]) }
      def before(args:, context:); end

      # The replaceable seam, run with the env only: the builder, the
      # packager, or the channel's protocol. Must return — a raise here is
      # the failure that skips `after`.
      #
      # @param env [Env] what `before` resolved
      # @param context [ExecutionContext]
      # @return [void]
      sig { abstract.params(env: Env, context: ExecutionContext).void }
      def seam(env, context:); end

      # The stage after a seam that returned: the stamp, the receipt, the
      # report line.
      #
      # @param env [Env] what `before` resolved
      # @param context [ExecutionContext]
      # @return [void]
      sig { abstract.params(env: Env, context: ExecutionContext).void }
      def after(env, context:); end
    end

    # Project command from a dev.yml `commands:` entry. Pure data: the run
    # string, optional description, repl flag, the environment it names
    # (`environment:`, an EnvironmentRef as written — the parser knows
    # nothing about images), the nested `commands:` as children — and, once
    # the composition root has bound the reference against the lock, its
    # Placement (with_placement). Whoever runs the command reads the bound
    # value; nothing downstream of the root resolves a name.
    class ProjectCommand
      extend T::Sig
      extend T::Helpers
      include Command
      final!

      # The placement was read before the composition root bound it. The
      # root binds every project command at load; it leaves the tree unbound
      # only when the lock itself cannot be read (it says so on stderr and
      # keeps the tree so the re-lock stays reachable), so a project command
      # asked to run then refuses rather than guess.
      class UnboundPlacementError < RuntimeError; end

      sig(:final) { returns(String) }
      attr_reader :run

      sig(:final) { override.returns(String) }
      attr_reader :desc

      sig(:final) { returns(T::Boolean) }
      attr_reader :repl

      # @return [EnvironmentRef, nil] the `environment:` value as declared;
      #   nil when the command leaves the choice to the project
      sig(:final) { returns(T.nilable(EnvironmentRef)) }
      attr_reader :environment

      # @return [Placement, nil] the environment bound against the lock; nil
      #   until the composition root binds it
      sig(:final) { returns(T.nilable(Placement)) }
      attr_reader :placement

      sig(:final) { override.returns(T::Hash[String, Command]) }
      attr_reader :children

      sig(:final) do
        params(
          run: String,
          desc: String,
          repl: T::Boolean,
          environment: T.nilable(EnvironmentRef),
          hidden: T::Boolean,
          children: T::Hash[String, Command],
          placement: T.nilable(Placement),
        ).void
      end
      def initialize(run:, desc: "(no description)", repl: false, environment: nil, hidden: false, children: {},
                     placement: nil)
        super()
        @run = run
        @desc = desc
        @repl = repl
        @environment = environment
        @hidden = hidden
        @children = T.let(children.freeze, T::Hash[String, Command])
        @placement = placement
      end

      # The bound placement, for whoever runs the command.
      #
      # @return [Placement]
      # @raise [UnboundPlacementError] when the composition root left the
      #   command unbound (the lock could not place it at load)
      sig(:final) { returns(Placement) }
      def placement!
        @placement || raise(UnboundPlacementError,
          "`#{@run}` has no environment bound: the lock could not place it at load — re-lock it (dev deps update) and retry")
      end

      # The same command with its environment bound (the composition root's
      # step between parsing and assembling the tree).
      #
      # @param placement [Placement]
      # @return [ProjectCommand]
      sig(:final) { params(placement: Placement).returns(ProjectCommand) }
      def with_placement(placement)
        ProjectCommand.new(
          run: @run, desc: @desc, repl: @repl, environment: @environment, hidden: @hidden, children: @children, placement:,
        )
      end

      sig(:final) { override.returns(T::Boolean) }
      def hidden?
        @hidden
      end

      sig(:final) { override.returns(Category) }
      def category
        Category::Project
      end

      # The run string owns its argv: dev has no vocabulary to check it
      # against, so every arg — `--help` included — reaches the script.
      sig(:final) { override.returns(T::Boolean) }
      def opaque_args?
        true
      end

      # The same command heading a different subtree (the repository's merge
      # of a project `run:` over a builtin group's children).
      #
      # @param children [Hash{String => Command}]
      # @return [ProjectCommand]
      sig(:final) { params(children: T::Hash[String, Command]).returns(ProjectCommand) }
      def with_children(children)
        ProjectCommand.new(
          run: @run, desc: @desc, repl: @repl, environment: @environment, hidden: @hidden, children:, placement: @placement,
        )
      end

      sig(:final) { params(other: Object).returns(T::Boolean) }
      def ==(other)
        return false unless other.is_a?(ProjectCommand)

        @run == other.run && @desc == other.desc && @repl == other.repl &&
          @environment == other.environment && @placement == other.placement &&
          @hidden == other.hidden? && @children == other.children
      end

      sig(:final) { params(other: Object).returns(T::Boolean) }
      def eql?(other)
        self == other
      end

      sig(:final) { returns(Integer) }
      def hash
        [@run, @desc, @repl, @environment, @placement, @hidden, @children].hash
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
      def desc
        @project.desc
      end

      sig(:final) { override.returns(T::Boolean) }
      def hidden?
        @project.hidden?
      end

      # Guard and stamp traits belong to the slot, not the override: a project
      # `up:` still is the provisioning command, so it inherits the builtin's
      # exemption and stamping behavior.
      sig(:final) { override.returns(T::Boolean) }
      def staleness_exempt?
        @builtin.staleness_exempt?
      end

      sig(:final) { override.returns(T::Boolean) }
      def stamps?
        @builtin.stamps?
      end

      # The argv belongs to the override: the project's run string receives
      # the same args as the builtin stage, and the script owns its flags —
      # so the slot is opaque, like any project command.
      sig(:final) { override.returns(T::Boolean) }
      def opaque_args?
        true
      end

      # So do the argument completions: the builtin knows its arguments, the
      # project body wrapping it runs after and takes the same ones.
      sig(:final) { override.params(words: T::Array[String]).returns(T::Array[String]) }
      def completions(words)
        @builtin.completions(words)
      end

      # The usage section belongs to the slot too: an overriding `up:` still
      # lists under Environment, with the project's description.
      sig(:final) { override.returns(Category) }
      def category
        @builtin.category
      end

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
      def hidden?
        @hidden
      end

      # Usage must work while stale — it is how the children get discovered
      # (same reason as HelpCommand) — and records nothing.
      sig(:final) { override.returns(T::Boolean) }
      def staleness_exempt?
        true
      end

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
end
