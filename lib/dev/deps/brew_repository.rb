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
        # The declared `version:` is a brew formula version *suffix* (e.g. "18"
        # selects the llvm@18 formula), not a semver to resolve — same meaning the
        # container build path gives it. The resolved stable version below is the
        # exact installed version, recorded for the lockfile.
        version_suffix = id["version"]

        if id["cask"]
          cask_metadata = { "cask" => true }
          cask_metadata["version_suffix"] = version_suffix if version_suffix
          return Dependency.new(
            name: name,
            integration: id["integration"].to_sym,
            group: id["group"].to_sym,
            version: nil,
            hash: nil,
            metadata: cask_metadata,
          )
        end

        info = brew_info(build_formula_spec(name, id["tap"], version_suffix))

        version = info["versions"]["stable"]
        bottle_hash = extract_bottle_hash(info)

        # env/host scoping is attached by the Resolver (attach_install_scoping),
        # not read from the fetch id — the id describes what the dep is.
        metadata = {}
        metadata["tap"] = id["tap"] if id["tap"]
        metadata["version_suffix"] = version_suffix if version_suffix

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

      # Build a brew formula spec: [tap/]name[@version_suffix]. Querying the
      # suffixed spec (e.g. "llvm@18") returns that versioned formula's stable
      # version and bottle, not the latest formula's.
      #
      # @param name [String] formula name
      # @param tap [String, nil] tap slug
      # @param version_suffix [String, nil] brew version suffix (e.g. "18")
      # @return [String]
      def build_formula_spec(name, tap, version_suffix)
        base = tap ? "#{tap}/#{name}" : name
        version_suffix ? "#{base}@#{version_suffix}" : base
      end

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
