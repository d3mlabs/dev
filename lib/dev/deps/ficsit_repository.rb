# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "repository"
require_relative "dependency"

module Dev
  module Deps
    # Fetches Satisfactory mod metadata from ficsit.app (Satisfactory Mod Repository).
    #
    # Uses the GraphQL API at api.ficsit.app/v2/query to resolve a mod_reference
    # to an exact version, integrity hash, and transitive mod dependencies.
    class FicsitRepository < Repository
      class ApiError < StandardError; end
      class ModNotFoundError < StandardError; end
      class NoVersionError < StandardError; end

      GRAPHQL_ENDPOINT = URI("https://api.ficsit.app/v2/query")

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

      # Resolve a ficsit.app mod dependency to a pinned Dependency.
      #
      # @param id [Hash] must include "name" (mod_reference), "integration", "group";
      #   optionally "version" (semver constraint like "^3.12.0"),
      #   "target" (e.g. "Windows", defaults to "Windows")
      # @return [Dependency]
      # @raise [ModNotFoundError] if the mod_reference doesn't exist on ficsit.app
      # @raise [NoVersionError] if no versions are available
      # @raise [ApiError] if the GraphQL request fails
      def fetch(id)
        mod_reference = id["name"]
        target = id.fetch("target", "Windows")
        mod_data = query_mod(mod_reference)
        versions = mod_data["versions"]
        raise NoVersionError, "no versions found for #{mod_reference}" if versions.nil? || versions.empty?

        version_data = versions.first
        target_data = find_target(version_data["targets"], target)
        hash = target_data ? "SHA256=#{target_data["hash"]}" : nil

        transitive_deps = (version_data["dependencies"] || [])
          .reject { |d| d["optional"] }
          .map { |d| { name: d["mod_id"], constraint: d["condition"] } }

        metadata = {
          "mod_id" => mod_data["id"],
          "game_version" => version_data["game_version"],
          "target" => target,
        }

        Dependency.new(
          name: mod_reference,
          integration: id["integration"].to_sym,
          group: id["group"].to_sym,
          version: version_data["version"],
          hash: hash,
          metadata: metadata,
          dependencies: transitive_deps,
        )
      end

      private

      # Query the ficsit.app GraphQL API for a mod by its mod_reference.
      #
      # @param mod_reference [String] mod reference (e.g. "SML", "AreaActions")
      # @return [Hash] parsed mod data from the API response
      # @raise [ModNotFoundError] if the mod is not found
      # @raise [ApiError] if the HTTP request fails or returns errors
      def query_mod(mod_reference)
        body = { query: VERSIONS_QUERY, variables: { modReference: mod_reference } }
        response = post_graphql(body)
        parsed = JSON.parse(response.body)

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
      def post_graphql(body)
        http = Net::HTTP.new(GRAPHQL_ENDPOINT.host, GRAPHQL_ENDPOINT.port)
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
      # @param targets [Array<Hash>, nil] target objects from the version
      # @param target_name [String] platform name (e.g. "Windows")
      # @return [Hash, nil] matching target or nil
      def find_target(targets, target_name)
        return nil if targets.nil? || targets.empty?

        targets.find { |t| t["targetName"] == target_name } || targets.first
      end
    end
  end
end
