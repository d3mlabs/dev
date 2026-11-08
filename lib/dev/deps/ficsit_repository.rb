# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/credentials"
require "dev/lifecycle/channel"
require "dev/lifecycle/publisher"
require "dev/lifecycle/receipt"
require "dev/lifecycle/shipment"
require "dev/lifecycle/track"
require_relative "artifact"
require_relative "declaration"
require_relative "declarations"
require_relative "ficsit_client"
require_relative "ficsit_stability"
require_relative "multi_target_plugin"
require_relative "multi_target_plugin_merger"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"

module Dev
  module Deps
    # The ficsit integration's two sides over one API — ficsit.app, the
    # Satisfactory Mod Repository (SMR), through its GraphQL endpoint
    # (FicsitClient).
    #
    # **Read side** (Repository#find): a mod_reference's published
    # versions, each with its targets, integrity hashes and transitive mod
    # dependencies.
    #
    # **Write side** (Lifecycle::Publisher#publish — the `ficsit` channel,
    # dev#192 K5, dev#427): the shipments `deploy` selected are per-target
    # Alpakit zips (one per build, `packager: as-is`); the publisher merges
    # them into SMR's multi-target zip (MultiTargetPluginMerger), finds the
    # mod by the reference the plugins carry, and uploads the zip as one
    # new version through SMR's chunked upload — `createVersion`, ten
    # megabyte `uploadVersionPart`s, `finalizeCreateVersion` with the
    # stability the track decides (FicsitStability: testing → beta, live →
    # release) — then waits for SMR to process it and reports the version
    # it made. The credential is the user's API key, `dev cred get ficsit
    # api_key` (or `FICSIT_API_KEY`); nothing in dev.yml names the mod —
    # the `.uplugin` does.
    class FicsitRepository < Repository
      extend T::Sig
      include Lifecycle::Publisher

      class ModNotFoundError < PackageNotFoundError; end

      # SMR answered `false` to a part or to the finalization without an
      # error of its own.
      class UploadRefusedError < RuntimeError; end

      # SMR did not finish processing the upload within the wait.
      class ProcessingTimedOutError < RuntimeError; end

      CHANNEL = "ficsit"

      # The chunk SMR's own frontend sends (`chunked-upload.ts`), and the
      # ceiling its part limit (100) leaves under the 1 GB archive limit.
      PART_SIZE = 10_000_000

      # How long `publish` waits for SMR to process the upload — the
      # frontend's own schedule.
      POLL_ATTEMPTS = 60
      POLL_INTERVAL_SECONDS = 10

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

      MOD_ID_QUERY = <<~GRAPHQL
        query GetModId($modReference: ModReference!) {
          getModByReference(modReference: $modReference) { id }
        }
      GRAPHQL

      CREATE_VERSION_MUTATION = <<~GRAPHQL
        mutation CreateVersion($modId: ModID!) {
          createVersion(modId: $modId)
        }
      GRAPHQL

      UPLOAD_PART_MUTATION = <<~GRAPHQL
        mutation UploadVersionPart($modId: ModID!, $versionId: VersionID!, $part: Int!, $file: Upload!) {
          uploadVersionPart(modId: $modId, versionId: $versionId, part: $part, file: $file)
        }
      GRAPHQL

      FINALIZE_MUTATION = <<~GRAPHQL
        mutation FinalizeCreateVersion($modId: ModID!, $versionId: VersionID!, $version: NewVersion!) {
          finalizeCreateVersion(modId: $modId, versionId: $versionId, version: $version)
        }
      GRAPHQL

      UPLOAD_STATE_QUERY = <<~GRAPHQL
        query CheckVersionUploadState($modId: ModID!, $versionId: VersionID!) {
          checkVersionUploadState(modId: $modId, versionId: $versionId) {
            auto_approved
            version { id version }
          }
        }
      GRAPHQL

      ApiKeySource = T.type_alias { T.proc.returns(String) }
      Sleeper = T.type_alias { T.proc.params(seconds: Integer).void }

      # The channel's credential: the API key a user makes on ficsit.app's
      # settings page, stored once with `dev cred` or set in the env.
      DEFAULT_API_KEY = T.let(
        lambda do
          Credentials.resolve(
            namespace: CHANNEL, key: "api_key", env_var: "FICSIT_API_KEY",
            prompt_label: "ficsit.app API key", create_url: "https://ficsit.app/settings",
          )
        end,
        ApiKeySource,
      )

      # What SMR made of an upload once processed (`CreateVersionResponse`).
      class PublishedVersion < T::Struct
        extend T::Sig

        const :id, String
        const :version, String
        const :auto_approved, T::Boolean

        sig { returns(String) }
        def to_s = "version #{version} (#{id}), #{auto_approved ? "auto-approved" : "awaiting approval"}"
      end

      # How the processing wait sleeps when nothing substitutes it: really.
      DEFAULT_SLEEPER = T.let(->(seconds) { Kernel.sleep(seconds) }, Sleeper)

      # @param client [FicsitClient] the API boundary
      # @param merger [MultiTargetPluginMerger] makes the multi-target zip
      # @param api_key [Proc] resolves the API key when a publish needs it
      # @param sleeper [Proc] how the processing wait sleeps (injectable for tests)
      # @param part_size [Integer] bytes per upload part (tests lower it to exercise the chunking)
      sig do
        params(client: FicsitClient, merger: MultiTargetPluginMerger, api_key: ApiKeySource, sleeper: Sleeper, part_size: Integer).void
      end
      def initialize(client: FicsitClient.new, merger: MultiTargetPluginMerger.new, api_key: DEFAULT_API_KEY,
                     sleeper: DEFAULT_SLEEPER, part_size: PART_SIZE)
        super()
        @client = client
        @merger = merger
        @api_key = api_key
        @sleeper = sleeper
        @part_size = part_size
      end

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
      # @return [Package]
      # @raise [ModNotFoundError] if the mod_reference doesn't exist on ficsit.app
      # @raise [FicsitClient::ApiError] if the GraphQL request fails
      sig { override.params(id: PackageId).returns(Package) }
      def find(id)
        mod_data = query_mod(VERSIONS_QUERY, id.name)
        versions = (mod_data["versions"] || []).map do |version_data|
          package_version(mod_data, version_data)
        end

        Package.new(id: id, versions: versions)
      end

      # Ship the selected per-target zips as one new version of their mod.
      #
      # @param shipments [Array<Lifecycle::Shipment>] one Alpakit per-target zip each
      # @param channel [Lifecycle::Channel]
      # @param track [Lifecycle::Track] decides the stability
      # @param scratch [Pathname] where the merge happens; created here
      # @return [Lifecycle::Receipt] the mod, the version SMR made and its stability
      # @raise [MultiTargetPluginMerger::ConflictingFileError] and the merger's other errors
      # @raise [ModNotFoundError] no mod on ficsit.app has the plugins' reference
      # @raise [UploadRefusedError]
      # @raise [ProcessingTimedOutError]
      # @raise [FicsitClient::ApiError] SMR's refusal, in its words
      # @raise [Credentials::MissingCredentialError] no API key and no terminal to ask on
      sig do
        override.params(shipments: T::Array[Lifecycle::Shipment], channel: Lifecycle::Channel, track: Lifecycle::Track, scratch: Pathname)
          .returns(Lifecycle::Receipt)
      end
      def publish(shipments, channel:, track:, scratch:)
        scratch.mkpath
        plugin = @merger.merge(shipments.map(&:archive), scratch:)
        token = @api_key.call
        mod_id = query_mod(MOD_ID_QUERY, plugin.mod_reference, token:).fetch("id")
        stability = FicsitStability.for_track(track)

        upload_id = create_version(mod_id, token)
        upload_parts(plugin, mod_id, upload_id, token)
        finalize(mod_id, upload_id, stability, changelog(shipments, channel, track), token)
        published = await_processing(plugin, mod_id, upload_id, token)

        Lifecycle::Receipt.new(summary: "ficsit: #{plugin} → #{stability}, #{published}")
      end

      # The declaration as `dev help` renders it.
      sig { returns(String) }
      def to_s = CHANNEL

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
        return "#{FicsitClient::HOST}#{link}" if link && !link.empty? && link.start_with?("/")
        return link if link && link.start_with?("http")

        "#{FicsitClient::HOST}/v1/version/#{version_data["id"]}/#{target_data["targetName"]}/download"
      end

      # Query ficsit.app for a mod by its mod_reference.
      #
      # @param document [String] a query over `getModByReference`
      # @param mod_reference [String] mod reference (e.g. "SML", "AreaActions")
      # @param token [String, nil] the API key, for the write side's calls
      # @return [Hash] the mod object
      # @raise [ModNotFoundError] if the mod is not found
      # @raise [FicsitClient::ApiError]
      sig { params(document: String, mod_reference: String, token: T.nilable(String)).returns(T::Hash[String, T.untyped]) }
      def query_mod(document, mod_reference, token: nil)
        mod_data = @client.query(document, { modReference: mod_reference }, token:)["getModByReference"]
        raise ModNotFoundError, "mod #{mod_reference} not found on ficsit.app" if mod_data.nil?

        mod_data
      end

      # Open an upload: SMR answers with the id the parts and the
      # finalization refer to, which becomes the version's id.
      #
      # @param mod_id [String]
      # @param token [String]
      # @return [String] the upload id
      # @raise [FicsitClient::ApiError] the mod is not approved, or lacks a disclosure SMR requires
      sig { params(mod_id: String, token: String).returns(String) }
      def create_version(mod_id, token)
        @client.query(CREATE_VERSION_MUTATION, { modId: mod_id }, token:).fetch("createVersion")
      end

      # Send the zip in parts numbered from 1.
      #
      # @param plugin [MultiTargetPlugin]
      # @param mod_id [String]
      # @param upload_id [String]
      # @param token [String]
      # @raise [UploadRefusedError]
      sig { params(plugin: MultiTargetPlugin, mod_id: String, upload_id: String, token: String).void }
      def upload_parts(plugin, mod_id, upload_id, token)
        plugin.archive.open("rb") do |file|
          part = 1
          while (chunk = file.read(@part_size))
            variables = { modId: mod_id, versionId: upload_id, part: }
            accepted = @client.upload(UPLOAD_PART_MUTATION, variables, file: chunk, filename: plugin.archive.basename.to_s, token:)
            raise UploadRefusedError, "ficsit.app refused part #{part} of #{plugin.archive.basename}" unless accepted.fetch("uploadVersionPart")

            part += 1
          end
        end
      end

      # Close the upload: SMR validates and splits the zip asynchronously
      # from here.
      #
      # @param mod_id [String]
      # @param upload_id [String]
      # @param stability [FicsitStability]
      # @param changelog [String]
      # @param token [String]
      # @raise [UploadRefusedError]
      sig { params(mod_id: String, upload_id: String, stability: FicsitStability, changelog: String, token: String).void }
      def finalize(mod_id, upload_id, stability, changelog, token)
        variables = { modId: mod_id, versionId: upload_id, version: { changelog:, stability: stability.serialize } }
        accepted = @client.query(FINALIZE_MUTATION, variables, token:).fetch("finalizeCreateVersion")
        raise UploadRefusedError, "ficsit.app refused to finalize upload #{upload_id}" unless accepted
      end

      # Poll until SMR has processed the upload into a version. A failure in
      # processing (a `.uplugin` that does not match, a version that exists)
      # comes back as a GraphQL error and is raised in SMR's words.
      #
      # @param plugin [MultiTargetPlugin]
      # @param mod_id [String]
      # @param upload_id [String]
      # @param token [String]
      # @return [PublishedVersion]
      # @raise [ProcessingTimedOutError]
      # @raise [FicsitClient::ApiError]
      sig { params(plugin: MultiTargetPlugin, mod_id: String, upload_id: String, token: String).returns(PublishedVersion) }
      def await_processing(plugin, mod_id, upload_id, token)
        POLL_ATTEMPTS.times do |attempt|
          @sleeper.call(POLL_INTERVAL_SECONDS) if attempt.positive?
          state = @client.query(UPLOAD_STATE_QUERY, { modId: mod_id, versionId: upload_id }, token:)["checkVersionUploadState"]
          version = state && state["version"]
          next unless version && version["id"]

          return PublishedVersion.new(id: version["id"], version: version["version"], auto_approved: state.fetch("auto_approved"))
        end

        raise ProcessingTimedOutError,
          "ficsit.app did not finish processing #{plugin.mod_reference}'s upload within #{POLL_ATTEMPTS * POLL_INTERVAL_SECONDS}s — " \
            "check the mod's versions page before deploying again"
      end

      # What SMR shows under the version: the one thing a publisher knows
      # that the plugin does not say — which builds, from where.
      #
      # @param shipments [Array<Lifecycle::Shipment>]
      # @param channel [Lifecycle::Channel]
      # @param track [Lifecycle::Track]
      # @return [String]
      sig { params(shipments: T::Array[Lifecycle::Shipment], channel: Lifecycle::Channel, track: Lifecycle::Track).returns(String) }
      def changelog(shipments, channel, track)
        ["dev deploy #{channel} (#{track} track)", *shipments.map { |shipment| "- #{shipment}" }].join("\n")
      end
    end
  end
end
