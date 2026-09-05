# typed: strict
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "artifact"
require_relative "dependency_edge"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"

module Dev
  module Deps
    # Fetches Satisfactory mod metadata from ficsit.app (Satisfactory Mod Repository).
    #
    # Uses the GraphQL API at api.ficsit.app/v2/query to resolve a mod_reference
    # to an exact version, integrity hash, and transitive mod dependencies.
    class FicsitRepository < Repository
      extend T::Sig

      class ApiError < StandardError; end
      class ModNotFoundError < PackageNotFoundError; end

      API_HOST = "https://api.ficsit.app"
      GRAPHQL_ENDPOINT = T.let(URI("#{API_HOST}/v2/query"), URI::Generic)
      DEFAULT_TARGET = "Windows"

      VERSIONS_QUERY = <<~GRAPHQL
        query GetMod($modReference: ModReference!) {
          getModByReference(modReference: $modReference) {
            id
            name
            mod_reference
            versions(filter: { limit: 100, order_by: created_at, order: desc }) {
              id
              version
              game_version
              targets {
                targetName
                hash
                size
                link
              }
              dependencies {
                mod_id
                condition
                optional
              }
            }
          }
        }
      GRAPHQL

      # Report a mod's published versions from ficsit.app.
      #
      # Each version carries its targets as platforms, each target's download
      # as an Artifact (dev-enforced integrity: the SHA256 the API publishes),
      # its required mod dependencies as edges, and the install facts
      # FicsitIntegration reads (mod_id, game_version, and either a
      # single-target digest or a per-platform block, per the filter).
      #
      # @param id [PackageId] name is the mod_reference
      # @param filter [Hash] locator only; "platforms" (Array<String, nil>)
      #   or "target" select which targets the install facts describe
      # @return [Package]
      # @raise [ModNotFoundError] if the mod_reference doesn't exist on ficsit.app
      # @raise [ApiError] if the GraphQL request fails
      sig { override.params(id: PackageId, filter: T::Hash[String, T.untyped]).returns(Package) }
      def find(id, filter: {})
        mod_data = query_mod(id.name)
        versions = (mod_data["versions"] || []).map do |version_data|
          package_version(mod_data, version_data, filter)
        end

        Package.new(id: id, versions: versions)
      end

      private

      # Map one GraphQL version object to a PackageVersion.
      #
      # Universe facts (platforms, artifacts, edges) are unconditional. The
      # install facts mirror the pin shapes FicsitIntegration reads: with
      # requested platforms, a metadata["platforms"] block covering the
      # targets this version actually publishes (the Resolver rejects the
      # version if a requested one is missing); otherwise the legacy
      # single-target shape (metadata["target"] plus the digest).
      #
      # @param mod_data [Hash] the mod object (for mod_id)
      # @param version_data [Hash] one version object
      # @param filter [Hash] the declaration constraint, as a locator
      # @return [PackageVersion]
      sig do
        params(
          mod_data: T::Hash[String, T.untyped],
          version_data: T::Hash[String, T.untyped],
          filter: T::Hash[String, T.untyped],
        ).returns(PackageVersion)
      end
      def package_version(mod_data, version_data, filter)
        targets = version_data["targets"] || []
        metadata = {
          "mod_id" => mod_data["id"],
          "game_version" => version_data["game_version"],
        }

        requested = filter["platforms"]
        if requested && !requested.empty?
          digest = nil
          metadata["platforms"] = platform_block(version_data, targets, requested)
        else
          target = filter.fetch("target", DEFAULT_TARGET)
          target_data = find_target(targets, target)
          digest = target_data ? "SHA256=#{target_data["hash"]}" : nil
          metadata["target"] = target
        end

        PackageVersion.new(
          version: version_data["version"],
          platforms: targets.map { |t| t["targetName"] },
          digest: digest,
          artifacts: targets.to_h do |t|
            [t["targetName"], Artifact.new(uri: download_url(version_data, t), digest: "SHA256=#{t["hash"]}")]
          end,
          dependencies: (version_data["dependencies"] || [])
            .reject { |d| d["optional"] }
            .map { |d| DependencyEdge.new(name: d["mod_id"], constraint: d["condition"]) },
          metadata: metadata,
        )
      end

      # The {hash, link} block for each requested platform this version
      # publishes. Non-raising: a missing target simply isn't in the block —
      # whether that disqualifies the version is the Resolver's call.
      #
      # @param version_data [Hash] the version object
      # @param targets [Array<Hash>] its target objects
      # @param requested [Array<String, nil>] platforms; nil means the default
      # @return [Hash{String => Hash}] target name → { "hash" => …, "link" => … }
      sig do
        params(
          version_data: T::Hash[String, T.untyped],
          targets: T::Array[T::Hash[String, T.untyped]],
          requested: T::Array[T.nilable(String)],
        ).returns(T::Hash[String, T::Hash[String, String]])
      end
      def platform_block(version_data, targets, requested)
        target_names = requested.map { |platform| platform.nil? ? DEFAULT_TARGET : platform }.uniq

        target_names.each_with_object({}) do |target_name, acc|
          target_data = targets.find { |t| t["targetName"] == target_name }
          next unless target_data

          acc[target_name] = {
            "hash" => "SHA256=#{target_data["hash"]}",
            "link" => download_url(version_data, target_data),
          }
        end
      end

      # Build the absolute download URL for a target. ficsit returns a relative
      # "link" (e.g. "/v1/version/<id>/<target>/download"); fall back to the same
      # REST shape if the field is ever absent.
      #
      # @param version_data [Hash]
      # @param target_data [Hash]
      # @return [String] absolute https URL
      sig do
        params(
          version_data: T::Hash[String, T.untyped],
          target_data: T::Hash[String, T.untyped],
        ).returns(String)
      end
      def download_url(version_data, target_data)
        link = target_data["link"]
        return "#{API_HOST}#{link}" if link && !link.empty? && link.start_with?("/")
        return link if link && link.start_with?("http")

        "#{API_HOST}/v1/version/#{version_data["id"]}/#{target_data["targetName"]}/download"
      end

      # Query the ficsit.app GraphQL API for a mod by its mod_reference.
      #
      # @param mod_reference [String] mod reference (e.g. "SML", "AreaActions")
      # @return [Hash] parsed mod data from the API response
      # @raise [ModNotFoundError] if the mod is not found
      # @raise [ApiError] if the HTTP request fails or returns errors
      sig { params(mod_reference: String).returns(T::Hash[String, T.untyped]) }
      def query_mod(mod_reference)
        body = { query: VERSIONS_QUERY, variables: { modReference: mod_reference } }
        response = post_graphql(body)
        parsed = JSON.parse(T.must(response.body))

        if parsed.key?("errors")
          messages = parsed["errors"].map { |e| e["message"] }.join("; ")
          raise ApiError, "ficsit.app GraphQL error for #{mod_reference}: #{messages}"
        end

        mod_data = parsed.dig("data", "getModByReference")
        raise ModNotFoundError, "mod #{mod_reference} not found on ficsit.app" if mod_data.nil?

        mod_data
      end

      # POST a GraphQL query to the ficsit.app API.
      #
      # @param body [Hash] request body with query and variables
      # @return [Net::HTTPResponse]
      # @raise [ApiError] if the HTTP response is not 2xx
      sig { params(body: T::Hash[Symbol, T.untyped]).returns(Net::HTTPResponse) }
      def post_graphql(body)
        http = Net::HTTP.new(T.must(GRAPHQL_ENDPOINT.host), GRAPHQL_ENDPOINT.port)
        http.use_ssl = true

        request = Net::HTTP::Post.new(GRAPHQL_ENDPOINT.path)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)

        response = http.request(request)
        unless response.is_a?(Net::HTTPSuccess)
          raise ApiError, "ficsit.app API returned #{response.code}: #{response.body}"
        end

        response
      end

      # Find the target matching the requested platform.
      #
      # @param targets [Array<Hash>] target objects from the version
      # @param target_name [String] platform name (e.g. "Windows")
      # @return [Hash, nil] matching target, or nil when targets is empty
      sig do
        params(
          targets: T::Array[T::Hash[String, T.untyped]],
          target_name: String,
        ).returns(T.nilable(T::Hash[String, T.untyped]))
      end
      def find_target(targets, target_name)
        targets.find { |t| t["targetName"] == target_name } || targets.first
      end
    end
  end
end
