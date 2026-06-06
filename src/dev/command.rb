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
  end

  # Shell command from dev.yml. Wraps a run string, optional description, and repl flag.
  # Final in the registry — duplicate declarations are an error.
  class ShellCommand < Command
    extend T::Sig

    sig { returns(String) }
    attr_reader :run

    sig { override.returns(String) }
    attr_reader :desc

    sig { returns(T::Boolean) }
    attr_reader :repl

    sig { params(run: String, desc: String, repl: T::Boolean).void }
    def initialize(run:, desc: "(no description)", repl: false)
      @run = T.let(run, String)
      @desc = T.let(desc, String)
      @repl = T.let(repl, T::Boolean)
    end

    sig { override.returns(T::Boolean) }
    def final? = true

    sig { override.params(args: T::Array[String], context: T.untyped).void }
    def execute(args:, context:)
      context.command_runner.run(self, args:)
    end

    sig { params(other: Object).returns(T::Boolean) }
    def ==(other)
      return false unless other.is_a?(ShellCommand)

      @run == other.run && @desc == other.desc && @repl == other.repl
    end

    sig { params(other: Object).returns(T::Boolean) }
    def eql?(other)
      self == other
    end

    sig { returns(Integer) }
    def hash
      [@run, @desc, @repl].hash
    end
  end
end
