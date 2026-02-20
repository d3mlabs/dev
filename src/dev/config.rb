# frozen_string_literal: true

module Dev
  # Value object for parsed dev.yml: repo name and command specs.
  class Config
    attr_reader :name, :commands

    def initialize(name:, commands:)
      @name = name.to_s.strip
      @commands = commands.is_a?(Hash) ? commands.freeze : {}
    end

    def command_spec(cmd_name)
      spec = commands[cmd_name]
      spec.is_a?(Hash) && spec["run"] ? spec : nil
    end
  end
end
