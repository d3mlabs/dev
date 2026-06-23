# typed: strict
# frozen_string_literal: true

module Dev
  # Base command interface. All command types implement #execute and #desc.
  #
  # - ShellCommand: wraps a shell run string from dev.yml (final)
  # - BuiltinCommand: wraps Ruby code (virtual / overridable)
  class Command
    extend T::Sig
    extend T::Helpers
    abstract!

    sig { abstract.params(args: T::Array[String], context: T.untyped).void }
    def execute(args:, context:); end

    sig { abstract.returns(String) }
    def desc; end

    # Whether this command slot is final (cannot be overridden).
    sig { abstract.returns(T::Boolean) }
    def final?; end

    # Whether this command is callable but omitted from `dev`/`dev --help`
    # usage. Used for internal plumbing (e.g. build primitives) a project keeps
    # invocable without advertising it. Visible by default.
    sig { returns(T::Boolean) }
    def hidden? = false
  end

  # Shell command from dev.yml. Wraps a run string, optional description, repl flag,
  # and container opt-out. When build.container is declared, commands run inside
  # the container by default unless container: false.
  # Final in the registry — duplicate declarations are an error.
  class ShellCommand < Command
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

    # Whether this command is omitted from usage output. Set via `hidden: true`
    # in dev.yml for internal build primitives that stay callable but unlisted.
    sig { returns(T::Boolean) }
    attr_reader :hidden

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
    def final? = true

    sig { override.returns(T::Boolean) }
    def hidden? = @hidden

    sig { override.params(args: T::Array[String], context: T.untyped).void }
    def execute(args:, context:)
      runner = CommandRunner.new(
        ui: context.ui,
        ruby_version: context.ruby_version,
        build_container: context.build_container,
        project_root: context.project_root,
      )
      runner.run(self, args:)
    end

    sig { params(other: Object).returns(T::Boolean) }
    def ==(other)
      return false unless other.is_a?(ShellCommand)

      @run == other.run && @desc == other.desc && @repl == other.repl &&
        @container == other.container && @hidden == other.hidden
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
end
