# typed: strict
# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "uri"
require_relative "declarations"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"

module Dev
  module Deps
    # Reports Homebrew formulae: the discrete universe is the formula-spec
    # family — the bare spec plus its versioned siblings (llvm, llvm@18, …),
    # each contributing the one stable version it currently has.
    #
    # Brew is a moving registry (one current version per spec), but the
    # family is enumerable first-class: `brew info --json=v1 <name>` reports
    # the bare spec's facts plus its versioned_formulae list, and one batched
    # info call fetches every sibling's facts. Each sibling's suffix rides
    # its version as the version_suffix fact BrewScheme's version: constraint
    # matches. Third-party tap formulae report an empty family and degrade to
    # a singleton universe. Casks are a separate universe
    # (BrewCaskRepository) under the :cask integration.
    #
    # Two more facts ride each version for the image build (reproducible
    # brew, A): `tap_commit`, the commit the formula's tap is at (brew's
    # `tap_git_head`), and `format` — "bottle" when the formula bottles for
    # the image platform, else "source" (the build compiles it). Brew's
    # local info for a core formula lists only this machine's bottle, so
    # core formats come from the public formula API.
    class BrewRepository < Repository
      extend T::Sig

      # The Homebrew core tap, whose formulae brew reads from the API.
      CORE_TAP = "homebrew/core"
      # The bottle tag of the build-container image's platform.
      IMAGE_BOTTLE_TAG = "x86_64_linux"
      FORMULA_API = "https://formulae.brew.sh/api/formula"
      FORMAT_BOTTLE = "bottle"
      FORMAT_SOURCE = "source"

      class BrewInfoError < StandardError; end

      # The public formula API did not answer for a core formula.
      class FormulaApiError < StandardError
        extend T::Sig

        # @param name [String] formula name
        # @param code [String] the HTTP status code
        sig { params(name: String, code: String).void }
        def initialize(name:, code:)
          super("#{FORMULA_API}/#{name}.json answered #{code}")
        end
      end

      # Report a brew formula's universe: the spec family's current stable
      # versions, bare spec last (the unconstrained pick — BrewScheme
      # preserves order and the Resolver takes the last version).
      #
      # The tap scoping the name is the package's source coordinate
      # (PackageId#source). Suffix and tap ride metadata as facts: BrewScheme
      # matches the suffix, BrewIntegration rebuilds the install spec from
      # both. Head-only siblings without a stable version are not versions
      # and are skipped.
      #
      # @param id [PackageId] name is the formula name; source is the tap
      # @return [Package] one version per family spec
      # @raise [BrewInfoError] if `brew info` fails for the formula
      sig { override.params(id: PackageId).returns(Package) }
      def find(id)
        tap = id.source
        base_info = brew_info_with_tap(build_formula_spec(id.name, tap), tap)

        family = T.let(base_info["versioned_formulae"] || [], T::Array[String])
        sibling_infos = family.empty? ? [] : brew_info_all(family.map { |name| build_formula_spec(name, tap) })

        versions = (sibling_infos + [base_info])
          .select { |info| info.dig("versions", "stable") }
          .map { |info| version_from(info, tap) }
        Package.new(id: id, versions: versions)
      end

      private

      # One family member's facts as a version: its stable version string,
      # its bottle digest, and the @suffix from its own spec name.
      #
      # @param info [Hash] parsed brew info JSON for one formula
      # @param tap [String, nil] tap slug from the id
      # @return [PackageVersion]
      sig { params(info: T::Hash[String, T.untyped], tap: T.nilable(String)).returns(PackageVersion) }
      def version_from(info, tap)
        bottle_hash = extract_bottle_hash(info)
        suffix = info["name"].to_s.split("@", 2)[1]

        metadata = {}
        metadata["tap"] = tap if tap
        metadata["version_suffix"] = suffix if suffix
        tap_commit = info["tap_git_head"]
        metadata["tap_commit"] = tap_commit if tap_commit
        metadata["format"] = image_format(info)

        PackageVersion.new(
          version: info["versions"]["stable"],
          digest: bottle_hash ? "SHA256=#{bottle_hash}" : nil,
          metadata: metadata,
          # brew installs formula dependencies itself.
          declarations: Declarations::ToolOwned.new,
        )
      end

      # Build a brew formula spec: [tap/]name.
      #
      # @param name [String] formula name (possibly @-suffixed already)
      # @param tap [String, nil] tap slug
      # @return [String]
      sig { params(name: String, tap: T.nilable(String)).returns(String) }
      def build_formula_spec(name, tap)
        tap ? "#{tap}/#{name}" : name
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
        T.must(brew_info_all([formula]).first)
      rescue BrewInfoError
        raise unless tap && register_tap(tap)

        T.must(brew_info_all([formula]).first)
      end

      # Query `brew info --json=v1` for one or more formulae in a single call.
      #
      # @param formulae [Array<String>] formula specs
      # @return [Array<Hash>] parsed JSON info, one entry per formula
      # @raise [BrewInfoError] if the command fails
      sig { params(formulae: T::Array[String]).returns(T::Array[T::Hash[String, T.untyped]]) }
      def brew_info_all(formulae)
        out, _err, status = T.unsafe(Open3).capture3("brew", "info", "--json=v1", *formulae)
        raise BrewInfoError, "brew info --json=v1 #{formulae.join(" ")} failed" unless status.success?

        JSON.parse(out)
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

      # How the image build gets this formula: from a bottle when one exists
      # for the image platform, otherwise by compiling from source.
      #
      # @param info [Hash] parsed brew info JSON for one formula
      # @return [String] FORMAT_BOTTLE or FORMAT_SOURCE
      sig { params(info: T::Hash[String, T.untyped]).returns(String) }
      def image_format(info)
        bottles = info["tap"] == CORE_TAP ? api_bottle_tags(info["name"].to_s) : bottle_tags(info)
        bottles.include?(IMAGE_BOTTLE_TAG) ? FORMAT_BOTTLE : FORMAT_SOURCE
      end

      # The bottle tags a formula's info lists.
      #
      # @param info [Hash] parsed formula JSON (brew info or the formula API)
      # @return [Array<String>]
      sig { params(info: T::Hash[String, T.untyped]).returns(T::Array[String]) }
      def bottle_tags(info)
        (info.dig("bottle", "stable", "files") || {}).keys
      end

      # A core formula's complete bottle list, from the public formula API.
      #
      # @param name [String] formula name
      # @return [Array<String>] bottle tags
      # @raise [FormulaApiError] if the API does not answer 2xx
      sig { params(name: String).returns(T::Array[String]) }
      def api_bottle_tags(name)
        response = get_formula_api(name)
        raise FormulaApiError.new(name:, code: response.code.to_s) unless response.is_a?(Net::HTTPSuccess)

        bottle_tags(JSON.parse(T.must(response.body)))
      end

      # @param name [String] formula name
      # @return [Net::HTTPResponse]
      sig { params(name: String).returns(Net::HTTPResponse) }
      def get_formula_api(name)
        Net::HTTP.get_response(URI("#{FORMULA_API}/#{name}.json"))
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
