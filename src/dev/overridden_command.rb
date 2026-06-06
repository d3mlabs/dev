# typed: strict
# frozen_string_literal: true

require_relative "command"

module Dev
  # A command that replaces a virtual (built-in) slot in the registry.
  # Calls super (the original built-in) first, then runs its own body.
  #
  # Mirrors OOP virtual dispatch: the override owns the slot, and its
  # implementation calls super() at the top before running its own logic.
  class OverriddenCommand < Command
    extend T::Sig

    sig { params(super_command: Command, body: Command).void }
    def initialize(super_command:, body:)
      @super_command = T.let(super_command, Command)
      @body = T.let(body, Command)
    end

    sig { override.returns(String) }
    def desc
      @super_command.desc
    end

    sig { override.params(args: T::Array[String], context: T.untyped).void }
    def execute(args:, context:)
      @super_command.execute(args:, context:)
      @body.execute(args:, context:)
    end
  end
end
