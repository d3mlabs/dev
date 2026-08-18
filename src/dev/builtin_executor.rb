# typed: strict
# frozen_string_literal: true

require_relative "command"
require_relative "execution_context"

module Dev
  # In-process execution of a builtin's Ruby body. The delegation is
  # deliberately thin: this class exists so CommandExecutor's three sealed
  # arms dispatch to uniformly injectable strategies (the builtin arm is
  # mocked in tests exactly like the process-boundary arms), not because
  # builtin execution needs any mediation.
  class BuiltinExecutor
    extend T::Sig

    # Run the builtin's body in the current process.
    #
    # @param command [BuiltinCommand]
    # @param args [Array<String>] argv after the command name
    # @param context [ExecutionContext]
    # @return [void]
    sig { params(command: BuiltinCommand, args: T::Array[String], context: ExecutionContext).void }
    def execute(command, args:, context:)
      command.call(args:, context:)
    end
  end
end
