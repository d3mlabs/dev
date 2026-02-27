# typed: strict
# frozen_string_literal: true

module Dev
  # Parses a dev.yml command hash into a Command value object.
  class CommandParser
    extend T::Sig

    # Values may be nil for optional keys.
    CommandHash = T.type_alias { T::Hash[String, T.any(String, TrueClass, FalseClass, NilClass)] }

    # @param cmd_hash [CommandHash] The command hash to parse.
    #
    # @return [Command] The parsed command.
    # @raise [ArgumentError] If the command hash is missing the `run` key or the value is not a string.
    sig { params(cmd_hash: CommandHash).returns(Command) }
    def parse(cmd_hash)
      run = cmd_hash["run"].to_s
      run_present = !run.empty?
      raise ArgumentError, "command missing 'run'" unless run_present

      # Coerces NilClass, TrueClass and FalseClass to String.
      desc = cmd_hash["desc"].to_s

      desc = desc.empty? ? "(no description)" : desc
      pretty_ui = cmd_hash["pretty_ui"] == true

      Command.new(run: run, desc: desc, pretty_ui: pretty_ui)
    end
  end
end
