# typed: strict
# frozen_string_literal: true

require "json"
require "open3"
require_relative "declarations"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"

module Dev
  module Deps
    # Fetches Homebrew formulae to exact version + bottle SHA256.
    #
    # Uses `brew info --json=v1` for formulae. Casks are a separate universe
    # (BrewCaskRepository) under the :cask integration.
    class BrewRepository < Repository
      extend T::Sig

      class BrewInfoError < StandardError; end

      # Report a brew formula's universe: the one stable version the selected
      # formula spec currently has.
      #
      # Brew is a moving registry — `brew info` answers with a single current
      # version per formula spec, so the universe is a singleton. Suffixed
      # formulae (llvm@18) are distinct formulae brew will not enumerate under
      # the bare name, which is why the probe (the declared suffix) is the
      # access path. The tap scoping the name is the package's source
      # coordinate (PackageId#source). The suffix and tap ride metadata as
      # facts: BrewScheme matches the suffix, BrewIntegration rebuilds the
      # install spec from both.
      #
      # @param id [PackageId] name is the formula name; source is the tap
      # @param probe [String, nil] formula version suffix ("18" selects llvm@18)
      # @return [Package] a singleton universe
      # @raise [BrewInfoError] if `brew info` fails for the formula
      sig { override.params(id: PackageId, probe: T.nilable(String)).returns(Package) }
      def find(id, probe: nil)
        tap = id.source
        info = brew_info_with_tap(build_formula_spec(id.name, tap, probe), tap)
        bottle_hash = extract_bottle_hash(info)

        metadata = {}
        metadata["tap"] = tap if tap
        metadata["version_suffix"] = probe if probe

        Package.new(
          id: id,
          versions: [
            PackageVersion.new(
              version: info["versions"]["stable"],
              digest: bottle_hash ? "SHA256=#{bottle_hash}" : nil,
              metadata: metadata,
              # brew installs formula dependencies itself.
              declarations: Declarations::ToolOwned.new,
            ),
          ],
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
      sig do
        params(
          name: String,
          tap: T.nilable(String),
          version_suffix: T.nilable(String),
        ).returns(String)
      end
      def build_formula_spec(name, tap, version_suffix)
        base = tap ? "#{tap}/#{name}" : name
        version_suffix ? "#{base}@#{version_suffix}" : base
      end

      # Query brew info, registering the declaration's tap first when the
      # initial query fails — resolving a `tap:`-scoped formula on a machine
      # that has never installed it requires the tap to be present.
      #
      # @param formula [String] formula spec (e.g. "xcodesorg/made/xcodes")
      # @param tap [String, nil] tap slug from the declaration
      # @return [Hash] parsed JSON info for the formula
      # @raise [BrewInfoError] if the command fails
      sig { params(formula: String, tap: T.nilable(String)).returns(T::Hash[String, T.untyped]) }
      def brew_info_with_tap(formula, tap)
        brew_info(formula)
      rescue BrewInfoError
        raise unless tap && register_tap(tap)

        brew_info(formula)
      end

      # Query `brew info --json=v1` for a formula.
      #
      # @param formula [String] formula spec (e.g. "cmake" or "d3mlabs/d3mlabs/powershell")
      # @return [Hash] parsed JSON info for the formula
      # @raise [BrewInfoError] if the command fails
      sig { params(formula: String).returns(T::Hash[String, T.untyped]) }
      def brew_info(formula)
        out, _err, status = Open3.capture3("brew", "info", "--json=v1", formula)
        raise BrewInfoError, "brew info --json=v1 #{formula} failed" unless status.success?

        JSON.parse(out).first
      end

      # @param tap [String] tap slug (e.g. "xcodesorg/made")
      # @return [Boolean] whether `brew tap` succeeded
      sig { params(tap: String).returns(T::Boolean) }
      def register_tap(tap)
        _out, _err, status = Open3.capture3("brew", "tap", tap)
        # success? is nil (not false) when the process didn't exit normally,
        # e.g. it was killed by a signal — coerce that to a failure.
        status.success? || false
      end

      # Extract the bottle SHA256 for the current platform.
      #
      # @param info [Hash] parsed brew info JSON
      # @return [String, nil] hex SHA256, or nil if no bottle found
      sig { params(info: T::Hash[String, T.untyped]).returns(T.nilable(String)) }
      def extract_bottle_hash(info)
        bottles = info.dig("bottle", "stable", "files") || {}
        current_arch = RUBY_PLATFORM.include?("arm") ? "arm64_sonoma" : "sonoma"
        bottle = bottles[current_arch] || bottles.values.first
        bottle&.fetch("sha256", nil)
      end
    end
  end
end
