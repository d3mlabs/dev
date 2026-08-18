# typed: strict
# frozen_string_literal: true

require_relative "builtin_body"
require_relative "execution_context"

module Dev
  # Sealed command data hierarchy. A command is one of exactly three shapes:
  #
  # - BuiltinCommand: a final wrapper delegating to the BuiltinBody it
  #   holds (bodies live under src/dev/builtins/)
  # - ProjectCommand: pure data parsed from a dev.yml `commands:` entry
  # - OverriddenCommand: a project command occupying a builtin's slot (the
  #   builtin runs first, like a hardcoded super())
  #
  # Sealing makes any other nesting unrepresentable: CommandExecutor
  # dispatches exhaustively over these three variants (case + T.absurd).
  # Sorbet requires the direct subclasses of a sealed class beside it, which
  # is why the whole hierarchy shares this file; every leaf is closed
  # (BuiltinCommand is final!), so the seal holds with no open edge.
  class Command
    extend T::Sig
    extend T::Helpers
    abstract!
    sealed!

    sig { abstract.returns(String) }
    def desc; end

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

  # Built-in command that executes Ruby code: a concrete, final wrapper
  # holding the BuiltinBody it delegates everything to. The Ruby bodies
  # live under src/dev/builtins/, one class per builtin; the composition
  # root wraps each in this leaf. final! means no subclasses can exist, so
  # Command's sealed runtime hook has nothing to reject — the hierarchy is
  # closed without reaching into sorbet-runtime internals.
  class BuiltinCommand < Command
    extend T::Sig
    extend T::Helpers
    final!

    sig(:final) { params(body: BuiltinBody).void }
    def initialize(body:)
      @body = T.let(body, BuiltinBody)
    end

    sig(:final) { override.returns(String) }
    def desc = @body.desc

    sig(:final) { override.returns(T::Boolean) }
    def hidden? = @body.hidden?

    sig(:final) { override.returns(T::Boolean) }
    def staleness_exempt? = @body.staleness_exempt?

    sig(:final) { override.returns(T::Boolean) }
    def stamps? = @body.stamps?

    sig(:final) { params(args: T::Array[String], context: ExecutionContext).void }
    def call(args:, context:) = @body.call(args:, context:)
  end

  # Project command from a dev.yml `commands:` entry. Pure data: the run
  # string, optional description, repl flag, and container opt-out. When
  # build.container is declared, commands run inside the container by
  # default unless container: false.
  class ProjectCommand < Command
    extend T::Sig

    sig { returns(String) }
    attr_reader :run

    sig { override.returns(String) }
    attr_reader :desc

    sig { returns(T::Boolean) }
    attr_reader :repl

    # Whether this command should run inside the build container (when one is
    # configured). Defaults to true; set to false via `container: false` in dev.yml.
    sig { returns(T::Boolean) }
    attr_reader :container

    sig do
      params(run: String, desc: String, repl: T::Boolean, container: T::Boolean, hidden: T::Boolean).void
    end
    def initialize(run:, desc: "(no description)", repl: false, container: true, hidden: false)
      @run = T.let(run, String)
      @desc = T.let(desc, String)
      @repl = T.let(repl, T::Boolean)
      @container = T.let(container, T::Boolean)
      @hidden = T.let(hidden, T::Boolean)
    end

    sig { override.returns(T::Boolean) }
    def hidden? = @hidden

    sig { params(other: Object).returns(T::Boolean) }
    def ==(other)
      return false unless other.is_a?(ProjectCommand)

      @run == other.run && @desc == other.desc && @repl == other.repl &&
        @container == other.container && @hidden == other.hidden?
    end

    sig { params(other: Object).returns(T::Boolean) }
    def eql?(other)
      self == other
    end

    sig { returns(Integer) }
    def hash
      [@run, @desc, @repl, @container, @hidden].hash
    end
  end

  # A project command occupying a builtin's slot. Mirrors OOP virtual
  # dispatch: the override owns the slot, and its implementation calls
  # super() at the top — CommandExecutor runs the builtin body first, then
  # the project command.
  class OverriddenCommand < Command
    extend T::Sig

    sig { returns(BuiltinCommand) }
    attr_reader :builtin

    sig { returns(ProjectCommand) }
    attr_reader :project

    sig { params(builtin: BuiltinCommand, project: ProjectCommand).void }
    def initialize(builtin:, project:)
      @builtin = T.let(builtin, BuiltinCommand)
      @project = T.let(project, ProjectCommand)
    end

    # The override owns the slot, so its description wins — a project `up:`
    # shows its own desc in usage, not the generic builtin one.
    sig { override.returns(String) }
    def desc = @project.desc

    sig { override.returns(T::Boolean) }
    def hidden? = @project.hidden?

    # Guard and stamp traits belong to the slot, not the override: a project
    # `up:` still is the provisioning command, so it inherits the builtin's
    # exemption and stamping behavior.
    sig { override.returns(T::Boolean) }
    def staleness_exempt? = @builtin.staleness_exempt?

    sig { override.returns(T::Boolean) }
    def stamps? = @builtin.stamps?
  end
end
