# typed: strict
# frozen_string_literal: true

module Dev
  # Value object for one command from dev.yml: run string, optional desc, optional repl flag.
  class Command
    extend T::Sig

    sig { returns(String) }
    attr_reader :run

    sig { returns(String) }
    attr_reader :desc

    sig { returns(T::Boolean) }
    attr_reader :repl

    sig { params(run: String, desc: String, repl: T::Boolean).void }
    def initialize(run:, desc: "(no description)", repl: false)
      @run = T.let(run, String)
      @desc = T.let(desc, String)
      @repl = T.let(repl, T::Boolean)
    end

    sig { params(other: Object).returns(T::Boolean) }
    def ==(other)
      return false unless other.is_a?(Command)
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
