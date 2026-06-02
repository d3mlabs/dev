# frozen_string_literal: true

require "json"
require "open3"
require_relative "repository"
require_relative "dependency"

module Dev
  module Deps
    # Fetches Homebrew formulae to exact version + bottle SHA256.
    #
    # Uses `brew info --json=v1` for formulae. Cask entries get no version
    # or hash (Homebrew doesn't expose bottle hashes for casks in the same way).
    class BrewRegistry < Repository
      def fetch(id)
        name = id["name"]

        if id["cask"]
          return Dependency.new(
            name: name,
            integration: id["integration"].to_sym,
            group: id["group"].to_sym,
            version: nil,
            hash: nil,
            metadata: { "cask" => true }.merge(env_metadata(id)),
          )
        end

        formula_spec = id["tap"] ? "#{id["tap"]}/#{name}" : name
        info = brew_info(formula_spec)

        version = info["versions"]["stable"]
        bottle_hash = extract_bottle_hash(info)

        metadata = {}
        metadata["tap"] = id["tap"] if id["tap"]
        metadata.merge!(env_metadata(id))

        Dependency.new(
          name: name,
          integration: id["integration"].to_sym,
          group: id["group"].to_sym,
          version: version,
          hash: bottle_hash ? "SHA256=#{bottle_hash}" : nil,
          metadata: metadata.empty? ? {} : metadata,
        )
      end

      private

      def brew_info(formula)
        out, _err, status = Open3.capture3("brew", "info", "--json=v1", formula)
        raise "brew info --json=v1 #{formula} failed" unless status.success?

        JSON.parse(out).first
      end

      def extract_bottle_hash(info)
        bottles = info.dig("bottle", "stable", "files") || {}
        current_arch = RUBY_PLATFORM.include?("arm") ? "arm64_sonoma" : "sonoma"
        bottle = bottles[current_arch] || bottles.values.first
        bottle&.fetch("sha256", nil)
      end

      def env_metadata(id)
        id["env"] ? { "env" => id["env"] } : {}
      end
    end
  end
end
