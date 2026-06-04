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
    #
    # Env scoping is not this layer's concern — the orchestrator handles
    # env filtering before and after resolution.
    class BrewRepository < Repository
      class BrewInfoError < StandardError; end

      # Resolve a brew dependency identifier to a pinned Dependency.
      #
      # For casks, returns a Dependency with nil version/hash.
      # For formulae, queries `brew info --json=v1` for the stable version
      # and bottle SHA256.
      #
      # @param id [Hash] must include "name", "integration", "group";
      #   optionally "tap", "cask"
      # @return [Dependency]
      # @raise [BrewInfoError] if `brew info` fails for a formula
      def fetch(id)
        name = id["name"]

        if id["cask"]
          return Dependency.new(
            name: name,
            integration: id["integration"].to_sym,
            group: id["group"].to_sym,
            version: nil,
            hash: nil,
            metadata: { "cask" => true },
          )
        end

        formula_spec = id["tap"] ? "#{id["tap"]}/#{name}" : name
        info = brew_info(formula_spec)

        version = info["versions"]["stable"]
        bottle_hash = extract_bottle_hash(info)

        metadata = {}
        metadata["tap"] = id["tap"] if id["tap"]

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

      # Query `brew info --json=v1` for a formula.
      #
      # @param formula [String] formula spec (e.g. "cmake" or "d3mlabs/d3mlabs/powershell")
      # @return [Hash] parsed JSON info for the formula
      # @raise [BrewInfoError] if the command fails
      def brew_info(formula)
        out, _err, status = Open3.capture3("brew", "info", "--json=v1", formula)
        raise BrewInfoError, "brew info --json=v1 #{formula} failed" unless status.success?

        JSON.parse(out).first
      end

      # Extract the bottle SHA256 for the current platform.
      #
      # @param info [Hash] parsed brew info JSON
      # @return [String, nil] hex SHA256, or nil if no bottle found
      def extract_bottle_hash(info)
        bottles = info.dig("bottle", "stable", "files") || {}
        current_arch = RUBY_PLATFORM.include?("arm") ? "arm64_sonoma" : "sonoma"
        bottle = bottles[current_arch] || bottles.values.first
        bottle&.fetch("sha256", nil)
      end
    end
  end
end
