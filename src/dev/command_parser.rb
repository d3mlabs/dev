# typed: strict
# frozen_string_literal: true

module Dev
  # Parses a dev.yml command hash into a Command value object.
  # Injected into ConfigParser; constructor can later accept config or flags.
  class CommandParser
    extend T::Sig

    # Keys: "run", "desc", "interactive". Values may be nil for optional keys.
    CommandHash = T.type_alias { T::Hash[String, T.any(String, TrueClass, FalseClass, NilClass)] }

    sig { void }
    def initialize; end

    sig { params(cmd_hash: CommandHash).returns(Command) }
    def parse(cmd_hash:)
      run = cmd_hash["run"]
      raise ArgumentError, "command missing 'run'" unless run.is_a?(String) && !run.empty?

      desc = cmd_hash["desc"]
      desc = T.cast(cmd_hash["desc"], T.nilable(String)) || "(no description)"
      interactive = cmd_hash["interactive"] == true

      Command.new(run: run, desc: desc, interactive: interactive)
    end
  end
end
