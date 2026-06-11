# typed: strict
# frozen_string_literal: true

require "yaml"
require_relative "command_parser"
require_relative "build_container_config"
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
      ruby_version = yaml["ruby"]&.to_s
      ruby_version = nil if ruby_version&.empty?
      build_container = parse_build_container(yaml)
      Config.new(
        name: T.cast(yaml["name"], String),
        commands: commands,
        ruby_version: ruby_version,
        build_container: build_container,
      )
    end

    private

    sig { params(yaml: T::Hash[String, T.untyped]).returns(T.nilable(BuildContainerConfig)) }
    def parse_build_container(yaml)
      build = yaml["build"]
      return nil unless build.is_a?(Hash)

      container = build["container"]
      return nil unless container.is_a?(Hash)

      image = container["image"]&.to_s
      registry = container["registry"]&.to_s
      return nil if image.nil? || image.empty? || registry.nil? || registry.empty?

      BuildContainerConfig.new(image: image, registry: registry)
    end
  end
end
