# frozen_string_literal: true

require "yaml"

module Dev
  # Parses dev.yml into a Config object.
  class ConfigParser
    def parse(dev_yml_path)
      yaml = YAML.load_file(dev_yml_path)
      Config.new(
        name: yaml["name"],
        commands: yaml["commands"]
      )
    end
  end
end
