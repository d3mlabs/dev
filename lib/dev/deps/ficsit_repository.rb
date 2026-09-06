# typed: strict
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "artifact"
require_relative "declaration"
require_relative "declarations"
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
      # its required mods as a Resolved declarations claim, and the mod facts
      # FicsitIntegration reads (mod_id, game_version). Which targets the pin
      # describes is not this universe's business: the Resolver projects the
      # declared platforms against the chosen version's artifacts at mint.
      #
      # @param id [PackageId] name is the mod_reference
      # @param probe [String, nil] ignored — the universe is enumerable
      # @return [Package]
      # @raise [ModNotFoundError] if the mod_reference doesn't exist on ficsit.app
      # @raise [ApiError] if the GraphQL request fails
      sig { override.params(id: PackageId, probe: T.nilable(String)).returns(Package) }
      def find(id, probe: nil)
        mod_data = query_mod(id.name)
        versions = (mod_data["versions"] || []).map do |version_data|
          package_version(mod_data, version_data)
        end

        Package.new(id: id, versions: versions)
      end

      private

      # Map one GraphQL version object to a PackageVersion: universe facts
      # only, unconditional — nothing here depends on who asked.
      #
      # @param mod_data [Hash] the mod object (for mod_id)
      # @param version_data [Hash] one version object
      # @return [PackageVersion]
      sig do
        params(
          mod_data: T::Hash[String, T.untyped],
          version_data: T::Hash[String, T.untyped],
        ).returns(PackageVersion)
      end
      def package_version(mod_data, version_data)
        targets = version_data["targets"] || []

        PackageVersion.new(
          version: version_data["version"],
          platforms: targets.map { |t| t["targetName"] },
          artifacts: targets.to_h do |t|
            [t["targetName"], Artifact.new(uri: download_url(version_data, t), digest: "SHA256=#{t["hash"]}")]
          end,
          declarations: Declarations::Resolved.new(
            (version_data["dependencies"] || [])
              .reject { |d| d["optional"] }
              .map { |d| edge_declaration(d) },
          ),
          metadata: {
            "mod_id" => mod_data["id"],
            "game_version" => version_data["game_version"],
          },
        )
      end

      # Normalize a ficsit dependency edge into a Declaration: the raw
      # "condition" (a semver range string, possibly absent) becomes dev's
      # constraint shape here, at the boundary — upstream syntax crosses into
      # the system exactly once. The integration is stamped by this
      # repository: ficsit mods require ficsit mods.
      #
      # @param dependency_data [Hash] one GraphQL dependency object
      # @return [Declaration]
      sig { params(dependency_data: T::Hash[String, T.untyped]).returns(Declaration) }
      def edge_declaration(dependency_data)
        condition = dependency_data["condition"]
        constraint = condition && !condition.empty? ? { "version" => condition } : {}
        Declaration.new(name: dependency_data["mod_id"], integration: :ficsit, constraint: constraint)
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
    end
  end
end
