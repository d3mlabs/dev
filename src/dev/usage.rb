# frozen_string_literal: true

module Dev
  # Prints usage/help for dev commands from a Config.
  class Usage
    def initialize(config)
      @config = config
    end

    def print
      puts "Usage: dev <command> [args...]"
      puts ""
      puts "Commands for #{@config.name}:"
      if @config.commands.empty?
        puts "  (no commands defined in dev.yml)"
      else
        @config.commands.each do |cmd, spec|
          desc = spec.is_a?(Hash) && spec["desc"] ? spec["desc"] : "(no description)"
          puts "  #{cmd.ljust(12)} #{desc}"
        end
      end
      puts ""
      puts "Examples: dev up    dev up -v    dev update-deps    dev test"
    end
  end
end
