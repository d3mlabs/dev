# typed: strict
# frozen_string_literal: true

module Dev
  # Value object for one command from dev.yml: run string, optional desc, optional use_pretty_ui flag.
  class Command
    extend T::Sig

    sig { returns(String) }
    attr_reader :run

    sig { returns(String) }
    attr_reader :desc

    sig { returns(T::Boolean) }
    attr_reader :pretty_ui

    sig { params(run: String, desc: String, pretty_ui: T::Boolean).void }
    def initialize(run:, desc: "(no description)", pretty_ui: true)
      @run = T.let(run, String)
      @desc = T.let(desc, String)
      @pretty_ui = T.let(pretty_ui, T::Boolean)
    end

    sig { params(other: Object).returns(T::Boolean) }
    def ==(other)
      return false unless other.is_a?(Command)
      @run == other.run && @desc == other.desc && @pretty_ui == other.pretty_ui
    end

    sig { params(other: Object).returns(T::Boolean) }
    def eql?(other)
      self == other
    end

    sig { returns(Integer) }
    def hash
      [@run, @desc, @pretty_ui].hash
    end
  end
end
