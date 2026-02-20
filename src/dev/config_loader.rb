# frozen_string_literal: true

require "yaml"

module Dev
  # Loads and parses dev.yml from a repository root; returns a Config or nil on error.
  class ConfigLoader
    def initialize(root)
      @root = root
      @path = File.join(root, RepoFinder::FILENAME)
    end

    def load
      return nil unless File.file?(@path)
      raw = YAML.load_file(@path)
      return nil unless raw.is_a?(Hash) && raw["commands"]
      Config.new(
        name: raw["name"] || "this repo",
        commands: raw["commands"]
      )
    rescue Psych::SyntaxError => e
      $stderr.puts "dev: invalid YAML in #{@path}: #{e.message}"
      nil
    end
  end
end
