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

    sig do
      params(
        desc: String,
        hidden: T::Boolean,
        block: T.proc.params(args: T::Array[String], context: T.untyped).void,
      ).void
    end
    def initialize(desc: "(no description)", hidden: false, &block)
      @desc = T.let(desc, String)
      @hidden = T.let(hidden, T::Boolean)
      @block = T.let(block, T.proc.params(args: T::Array[String], context: T.untyped).void)
    end

    sig { override.returns(T::Boolean) }
    def final? = false

    sig { override.returns(T::Boolean) }
    def hidden? = @hidden

    sig { override.params(args: T::Array[String], context: T.untyped).void }
    def execute(args:, context:)
      @block.call(args, context)
    end
  end
end
