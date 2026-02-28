# typed: strict
# frozen_string_literal: true

require "yaml"
require_relative "command_parser"
require "pathname"

module Dev
  # Parses dev.yml into a Config object.
  class ConfigParser
    extend T::Sig
    extend T::Helpers

    sig { params(command_parser: CommandParser).void }
    def initialize(command_parser:)
      @command_parser = T.let(command_parser, CommandParser)
    end

    sig { params(dev_yml_path: Pathname).returns(Config) }
    def parse(dev_yml_path)
      yaml = YAML.load_file(dev_yml_path)
      raw_commands = yaml["commands"] || {}
      commands = raw_commands.transform_values { |h| @command_parser.parse(h) }
      Config.new(
        name: T.cast(yaml["name"], String),
        commands: commands
      )
    end
  end
end
