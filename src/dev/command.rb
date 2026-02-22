# typed: strict
# frozen_string_literal: true

module Dev
  # Value object for one command from dev.yml: run string, optional desc, optional interactive flag.
  class Command
    extend T::Sig

    sig { returns(String) }
    attr_reader :run

    sig { returns(String) }
    attr_reader :desc

    sig { returns(T::Boolean) }
    attr_reader :interactive

    sig { params(run: String, desc: String, interactive: T::Boolean).void }
    def initialize(run:, desc: "(no description)", interactive: false)
      @run = T.let(run, String)
      @desc = T.let(desc, String)
      @interactive = T.let(interactive, T::Boolean)
    end
  end
end
