# typed: strict
# frozen_string_literal: true

require_relative "command"

module Dev
  # Parses a dev.yml command hash into a ProjectCommand value object.
  class CommandParser
    extend T::Sig

    # Values may be nil for optional keys.
    CommandHash = T.type_alias { T::Hash[String, T.any(String, TrueClass, FalseClass, NilClass)] }

    # @param cmd_hash [CommandHash] The command hash to parse.
    #
    # @return [ProjectCommand] The parsed command.
    # @raise [ArgumentError] If the command hash is missing the `run` key or the value is not a string.
    sig { params(cmd_hash: CommandHash).returns(ProjectCommand) }
    def parse(cmd_hash)
      run = cmd_hash["run"].to_s
      run_present = !run.empty?
      raise ArgumentError, "command missing 'run'" unless run_present

      # Coerces NilClass, TrueClass and FalseClass to String.
      desc = cmd_hash["desc"].to_s

      desc = desc.empty? ? "(no description)" : desc
      repl = cmd_hash["repl"] == true
      container = cmd_hash["container"] != false
      hidden = cmd_hash["hidden"] == true

      ProjectCommand.new(run: run, desc: desc, repl: repl, container: container, hidden: hidden)
    end
  end
end
