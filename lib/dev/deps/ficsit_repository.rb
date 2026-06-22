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
      class TargetNotFoundError < StandardError; end

      API_HOST = "https://api.ficsit.app"
      GRAPHQL_ENDPOINT = URI("#{API_HOST}/v2/query")
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

      # Resolve a ficsit.app mod dependency to a pinned Dependency.
      #
      # Two shapes, selected by the fetch id:
      # - Multi-platform (id["platforms"] present): resolve the mod for every
      #   requested platform and nest each platform's {hash, link} under
      #   metadata["platforms"]. nil entries map to the default target (Windows).
      #   The top-level hash is nil since integrity is tracked per platform.
      # - Single-platform (legacy): resolve one "target" (default Windows) and
      #   carry the hash on the Dependency, as before.
      #
      # @param id [Hash] must include "name" (mod_reference), "integration", "group";
      #   optionally "version" (semver constraint like "^3.12.0"),
      #   "target" (e.g. "Windows") or "platforms" (Array<String, nil>)
      # @return [Dependency]
      # @raise [ModNotFoundError] if the mod_reference doesn't exist on ficsit.app
      # @raise [NoVersionError] if no versions are available
      # @raise [TargetNotFoundError] if a requested platform has no published target
      # @raise [ApiError] if the GraphQL request fails
      def fetch(id)
        mod_reference = id["name"]
        mod_data = query_mod(mod_reference)
        versions = mod_data["versions"]
        raise NoVersionError, "no versions found for #{mod_reference}" if versions.nil? || versions.empty?

        version_data = versions.first
        metadata = {
          "mod_id" => mod_data["id"],
          "game_version" => version_data["game_version"],
        }

        requested = id["platforms"]
        if requested && !requested.empty?
          metadata["platforms"] = resolve_platforms(mod_reference, version_data, requested)
          hash = nil
        else
          target = id.fetch("target", DEFAULT_TARGET)
          target_data = find_target(version_data["targets"], target)
          hash = target_data ? "SHA256=#{target_data["hash"]}" : nil
          metadata["target"] = target
        end

        transitive_deps = (version_data["dependencies"] || [])
          .reject { |d| d["optional"] }
          .map { |d| { name: d["mod_id"], constraint: d["condition"] } }

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

      # Resolve each requested platform to its {hash, link}, keyed by the actual
      # ficsit target name. nil maps to the default target; unlike the legacy
      # single-target path, a missing platform is a hard error here because the
      # caller asked for that specific arch.
      #
      # @param mod_reference [String] for error messages
      # @param version_data [Hash] the chosen version object
      # @param requested [Array<String, nil>] platforms to resolve
      # @return [Hash{String => Hash}] target name → { "hash" => …, "link" => … }
      # @raise [TargetNotFoundError] if a requested platform has no target
      def resolve_platforms(mod_reference, version_data, requested)
        targets = version_data["targets"] || []
        target_names = requested.map { |platform| platform.nil? ? DEFAULT_TARGET : platform }.uniq

        target_names.each_with_object({}) do |target_name, acc|
          target_data = targets.find { |t| t["targetName"] == target_name }
          unless target_data
            available = targets.map { |t| t["targetName"] }.join(", ")
            raise TargetNotFoundError,
                  "#{mod_reference} #{version_data["version"]} has no #{target_name} target (available: #{available})"
          end

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
