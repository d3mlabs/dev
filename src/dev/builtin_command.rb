# typed: strict
# frozen_string_literal: true

require_relative "command"

module Dev
  # Built-in command that executes Ruby code.
  # Virtual in the registry — can be overridden by a project command.
  class BuiltinCommand < Command
    extend T::Sig

    sig { override.returns(String) }
    attr_reader :desc

    sig { params(desc: String, block: T.proc.params(args: T::Array[String], context: T.untyped).void).void }
    def initialize(desc: "(no description)", &block)
      @desc = T.let(desc, String)
      @block = T.let(block, T.proc.params(args: T::Array[String], context: T.untyped).void)
    end

    sig { override.returns(T::Boolean) }
    def final? = false

    sig { override.params(args: T::Array[String], context: T.untyped).void }
    def execute(args:, context:)
      @block.call(args:, context:)
    end
  end
end
