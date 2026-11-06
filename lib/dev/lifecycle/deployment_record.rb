# typed: strict
# frozen_string_literal: true

require_relative "artifact"
require_relative "build_id"
require_relative "deployment_state"
require_relative "track"

module Dev
  module Lifecycle
    # What dev records of one deploy (dev#192, K6): the **channel** it went
    # to (the GitHub Deployment's environment), the **ref** it was made
    # from (the artifacts' snapshot sha, or the release's tag), the
    # **track**, the **builds** that shipped with the ids they were
    # packaged under, and how it ended — the state and, in the status's
    # description, the publisher's Receipt on success or the failure's
    # message. A deploy produces no node of the store (K0): this record on
    # the forge is its only trace, shared by the operator's Mac and the
    # box's CI and keyed the way people think, channel × ref.
    #
    # A build is carried by name, not as a Build: the ledger outlives the
    # declarations (a target renamed last month still shipped), so reading
    # a record never needs the project's targets.
    class DeploymentRecord < T::Struct
      extend T::Sig

      # An artifact packaged outside a checkout carries no commit, so there
      # is nothing on the forge to record its deploy against.
      class UnknownRefError < RuntimeError; end

      # A payload read back from the forge that is not a record dev wrote:
      # a missing key, a word outside the vocabulary.
      class MalformedPayloadError < RuntimeError; end

      # The payload's shape version; bumped when a reader of today's shape
      # could not read tomorrow's.
      SCHEMA = 1

      JsonHash = T.type_alias { T::Hash[String, T.untyped] }

      # One build the deploy shipped, with the id it was packaged under.
      class DeployedBuild < T::Struct
        extend T::Sig

        const :name, String
        const :build_id, BuildId

        # @return [Hash] the JSON shape
        sig { returns(JsonHash) }
        def to_json_hash = { "build" => name, "build_id" => build_id.to_s }

        sig { returns(String) }
        def to_s = "#{name} (#{build_id})"

        sig { params(other: Object).returns(T::Boolean) }
        def ==(other) = other.is_a?(DeployedBuild) && name == other.name && build_id == other.build_id

        sig { params(other: Object).returns(T::Boolean) }
        def eql?(other) = self == other

        sig { returns(Integer) }
        def hash = [DeployedBuild, name, build_id].hash
      end

      const :channel, String
      const :ref, String
      const :track, Track
      # In accept order.
      const :builds, T::Array[DeployedBuild]
      const :state, DeploymentState
      # The receipt's summary on success, the failure's message otherwise;
      # nil when the status said nothing.
      const :description, T.nilable(String)

      class << self
        extend T::Sig

        # The records one deploy of these artifacts makes: one per commit
        # the artifacts were packaged from — one in the common case, more
        # only when `--allow-stale` shipped artifacts of different commits
        # together, since a GitHub Deployment is one (environment, ref).
        #
        # @param artifacts [Array<Artifact>] what shipped, in accept order
        # @param channel [String] the channel's name
        # @param track [Track]
        # @param state [DeploymentState]
        # @param description [String, nil]
        # @return [Array<DeploymentRecord>] in order of first appearance
        # @raise [UnknownRefError]
        sig do
          params(
            artifacts: T::Array[Artifact],
            channel: String,
            track: Track,
            state: DeploymentState,
            description: T.nilable(String),
          ).returns(T::Array[DeploymentRecord])
        end
        def of(artifacts, channel:, track:, state:, description:)
          artifacts.group_by { |artifact| ref_of(artifact) }.map do |ref, shipped|
            new(
              channel:,
              ref:,
              track:,
              builds: shipped.map { |artifact| DeployedBuild.new(name: artifact.name, build_id: artifact.manifest.build_id) },
              state:,
              description:,
            )
          end
        end

        # A record read back from the forge: the deployment's own fields
        # plus the payload dev wrote and the latest status.
        #
        # @param payload [Object] the deployment's `payload` as the API returned it
        # @param channel [String] the deployment's environment
        # @param ref [String]
        # @param state [DeploymentState]
        # @param description [String, nil]
        # @return [DeploymentRecord]
        # @raise [MalformedPayloadError]
        sig do
          params(
            payload: T.untyped,
            channel: String,
            ref: String,
            state: DeploymentState,
            description: T.nilable(String),
          ).returns(DeploymentRecord)
        end
        def from_payload(payload, channel:, ref:, state:, description:)
          raise MalformedPayloadError, "deployment payload is not an object: #{payload.inspect}" unless payload.is_a?(Hash)

          builds = payload.fetch("builds")
          raise MalformedPayloadError, "deployment payload lists no builds" unless builds.is_a?(Array)

          new(
            channel:,
            ref:,
            track: Track.parse(payload.fetch("track").to_s),
            builds: builds.map do |entry|
              raise MalformedPayloadError, "deployment payload build is not an object: #{entry.inspect}" unless entry.is_a?(Hash)

              DeployedBuild.new(name: entry.fetch("build").to_s, build_id: BuildId.new(entry.fetch("build_id").to_s))
            end,
            state:,
            description:,
          )
        rescue KeyError, UnknownTrackError, BuildId::MalformedBuildIdError => e
          raise MalformedPayloadError, "deployment payload is not one dev wrote: #{e.message}"
        end

        private

        # @param artifact [Artifact]
        # @return [String] the commit it was packaged from
        # @raise [UnknownRefError]
        sig { params(artifact: Artifact).returns(String) }
        def ref_of(artifact)
          artifact.manifest.state.sha ||
            raise(UnknownRefError, "#{artifact.name} (#{artifact.manifest.build_id}) was packaged outside a checkout: no commit to record its deploy against")
        end
      end

      # The deployment's payload: what dev wrote, read back by `status`.
      #
      # @return [Hash] the JSON shape
      sig { returns(JsonHash) }
      def payload
        { "schema" => SCHEMA, "track" => track.to_s, "builds" => builds.map(&:to_json_hash) }
      end

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        other.is_a?(DeploymentRecord) && channel == other.channel && ref == other.ref && track == other.track &&
          builds == other.builds && state == other.state && description == other.description
      end

      sig { params(other: Object).returns(T::Boolean) }
      def eql?(other) = self == other

      sig { returns(Integer) }
      def hash = [DeploymentRecord, channel, ref, track, builds, state, description].hash
    end
  end
end
