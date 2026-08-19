# typed: strict
# frozen_string_literal: true

require_relative "execution_context"

module Dev
  # Sealed command hierarchy. A command is one of exactly three shapes:
  #
  # - BuiltinCommand: a Ruby body dev ships (an abstract class, the
  #   hierarchy's one declared open edge; subclasses live under
  #   src/dev/builtins/)
  # - ProjectCommand: pure data parsed from a dev.yml `commands:` entry
  # - OverriddenCommand: a project command occupying a builtin's slot (the
  #   builtin runs first, like a hardcoded super())
  #
  # Sealing makes a fourth variant unrepresentable: CommandExecutor
  # dispatches exhaustively over these three (case + T.absurd), and Sorbet
  # requires a sealed module's direct heirs beside it, which is why the
  # hierarchy shares this file.
  #
  # Command is a module rather than a class deliberately. A sealed class's
  # runtime `inherited` hook rides down the singleton chain to every
  # descendant, so builtins subclassing an abstract BuiltinCommand class
  # raise at definition time unless sorbet-runtime internals are faked open
  # (the ivar pokes this file used to carry). A sealed module's `included`
  # hook fires only for its direct includers — the three heirs below —
  # because `include` never transfers singleton methods, so subclassing
  # BuiltinCommand is an honest open edge with nothing to suppress. Descent
  # is closed everywhere it is not explicitly declared: the two data leaves
  # are final!.
  module Command
    extend T::Sig
    extend T::Helpers
    abstract!
    sealed!

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

    sig { abstract.params(args: T::Array[String], context: ExecutionContext).void }
    def call(args:, context:); end
  end

  # Project command from a dev.yml `commands:` entry. Pure data: the run
  # string, optional description, repl flag, and container opt-out. When
  # build.container is declared, commands run inside the container by
  # default unless container: false.
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

    sig(:final) do
      params(run: String, desc: String, repl: T::Boolean, container: T::Boolean, hidden: T::Boolean).void
    end
    def initialize(run:, desc: "(no description)", repl: false, container: true, hidden: false)
      super()
      @run = T.let(run, String)
      @desc = T.let(desc, String)
      @repl = T.let(repl, T::Boolean)
      @container = T.let(container, T::Boolean)
      @hidden = T.let(hidden, T::Boolean)
    end

    sig(:final) { override.returns(T::Boolean) }
    def hidden? = @hidden

    sig(:final) { override.returns(Category) }
    def category = Category::Project

    sig(:final) { params(other: Object).returns(T::Boolean) }
    def ==(other)
      return false unless other.is_a?(ProjectCommand)

      @run == other.run && @desc == other.desc && @repl == other.repl &&
        @container == other.container && @hidden == other.hidden?
    end

    sig(:final) { params(other: Object).returns(T::Boolean) }
    def eql?(other)
      self == other
    end

    sig(:final) { returns(Integer) }
    def hash
      [@run, @desc, @repl, @container, @hidden].hash
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

    sig(:final) { params(builtin: BuiltinCommand, project: ProjectCommand).void }
    def initialize(builtin:, project:)
      super()
      @builtin = T.let(builtin, BuiltinCommand)
      @project = T.let(project, ProjectCommand)
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

    # The usage section belongs to the slot too: an overriding `up:` still
    # lists under Lifecycle, with the project's description.
    sig(:final) { override.returns(Category) }
    def category = @builtin.category
  end
end
