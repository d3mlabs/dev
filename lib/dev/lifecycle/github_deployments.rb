# typed: strict
# frozen_string_literal: true

require "json"
require "time"
require "uri"
require_relative "deployment"
require_relative "deployment_record"
require_relative "deployment_state"
require_relative "gh"

module Dev
  module Lifecycle
    # The deployment ledger on the forge (dev#192, K6): each deploy is a
    # GitHub Deployment — `environment` the channel, `ref` the snapshot
    # sha or the tag, the payload dev's record of builds and track — with
    # one status saying how it ended and carrying the receipt. It lives on
    # the forge rather than in a data root because the operator's Mac and
    # the box's CI would otherwise hold different truths; and it is
    # GitHub's own object rather than an issue or a file so the repo UI
    # shows it unaided.
    #
    # Two of GitHub's defaults are turned off on every write, because a
    # deploy is a record, not a request: `auto_merge` (GitHub would merge
    # the default branch into the ref first) and `required_contexts`
    # (GitHub would refuse the record while a check on the commit is not
    # green). A `--release` deploy marks the environment `production` —
    # the live track — so the UI tells the two apart.
    #
    # The repo is read from the checkout on first use, not at
    # construction: the ledger is wired into every `dev` run that has a
    # channel, and a gh call at load would tax `dev help`.
    class GithubDeployments
      extend T::Sig

      # Any failure of the ledger; the subclasses say which.
      class Error < RuntimeError; end

      # gh could not read the checkout's repo (no `origin`, not a GitHub
      # remote, gh not authenticated).
      class RepoUnresolvedError < Error; end

      # The API refused a write or a read; the message carries gh's words
      # (a 422 for a ref the forge does not have, a token without
      # `deployments: write`).
      class ApiError < Error; end

      # The API answered with something that is not a deployment dev
      # wrote or can read.
      class MalformedDeploymentError < Error; end

      # GitHub refuses a status description longer than this.
      DESCRIPTION_LIMIT = 140
      # The forge's spelling of a rendered page for one environment.
      DEPLOYMENTS_PAGE = "https://github.com/%<repo>s/deployments/%<channel>s"

      JsonHash = T.type_alias { T::Hash[String, T.untyped] }

      # @param gh [Gh] over the project's checkout
      sig { params(gh: Gh).void }
      def initialize(gh:)
        @gh = gh
        @repo = T.let(nil, T.nilable(String))
      end

      # Record one deploy: create the deployment, then its one status.
      #
      # @param record [DeploymentRecord]
      # @return [Deployment] as the forge holds it
      # @raise [RepoUnresolvedError]
      # @raise [ApiError]
      # @raise [MalformedDeploymentError]
      sig { params(record: DeploymentRecord).returns(Deployment) }
      def record(record)
        created = api("repos/#{repo}/deployments", method: "POST", body: {
          "ref" => record.ref,
          "environment" => record.channel,
          "description" => "dev deploy #{record.channel}: #{record.builds.map(&:name).join(", ")}",
          "payload" => record.payload,
          "auto_merge" => false,
          "required_contexts" => [],
          "production_environment" => record.track.live?,
        })
        id = Integer(fetch(created, "id"))
        api("repos/#{repo}/deployments/#{id}/statuses", method: "POST", body: {
          "state" => record.state.to_s,
          "description" => record.description.to_s[0, DESCRIPTION_LIMIT],
        })
        Deployment.new(record:, id:, created_at: Time.iso8601(fetch(created, "created_at").to_s), url: page(record.channel))
      rescue ArgumentError, TypeError => e
        raise MalformedDeploymentError, "the created deployment could not be read back: #{e.message}"
      end

      # The most recent deployment of a channel — of one ref when given
      # (the release's tag) — with its latest status; nil when the channel
      # has none.
      #
      # @param channel [String]
      # @param ref [String, nil]
      # @return [Deployment, nil]
      # @raise [RepoUnresolvedError]
      # @raise [ApiError]
      # @raise [MalformedDeploymentError]
      sig { params(channel: String, ref: T.nilable(String)).returns(T.nilable(Deployment)) }
      def latest(channel:, ref: nil)
        query = { "environment" => channel, "per_page" => 1 }
        query["ref"] = ref if ref
        deployment = list("repos/#{repo}/deployments?#{URI.encode_www_form(query)}").first
        return nil if deployment.nil?

        id = Integer(fetch(deployment, "id"))
        status = list("repos/#{repo}/deployments/#{id}/statuses?per_page=1").first
        Deployment.new(
          record: DeploymentRecord.from_payload(
            deployment["payload"],
            channel:,
            ref: fetch(deployment, "ref").to_s,
            state: status ? DeploymentState.parse(fetch(status, "state").to_s) : DeploymentState::Pending,
            description: status&.fetch("description", nil)&.to_s,
          ),
          id:,
          created_at: Time.iso8601(fetch(deployment, "created_at").to_s),
          url: page(channel),
        )
      rescue DeploymentRecord::MalformedPayloadError, UnknownDeploymentStateError, ArgumentError, TypeError => e
        raise MalformedDeploymentError, "deployment of #{channel} could not be read: #{e.message}"
      end

      # The repo's deployments page for a channel.
      #
      # @param channel [String]
      # @return [String]
      # @raise [RepoUnresolvedError]
      sig { params(channel: String).returns(String) }
      def page(channel) = format(DEPLOYMENTS_PAGE, repo:, channel:)

      private

      # "owner/repo" of the checkout, as gh resolves it; read once.
      #
      # @return [String]
      # @raise [RepoUnresolvedError]
      sig { returns(String) }
      def repo
        @repo ||= begin
          out = @gh.capture(["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"]).strip
          raise RepoUnresolvedError, "gh named no repo for #{@gh.root}" if out.empty?

          out
        rescue Gh::CommandFailedError => e
          raise RepoUnresolvedError, "could not resolve the repo of #{@gh.root}: #{e.message}"
        end
      end

      # One API call, its JSON answer as an object.
      #
      # @param path [String]
      # @param method [String, nil] GET when nil
      # @param body [Hash, nil] sent as JSON through stdin
      # @return [Hash]
      # @raise [ApiError]
      # @raise [MalformedDeploymentError]
      sig { params(path: String, method: T.nilable(String), body: T.nilable(JsonHash)).returns(JsonHash) }
      def api(path, method: nil, body: nil)
        answer = call(path, method:, body:)
        raise MalformedDeploymentError, "gh api #{path} answered with #{answer.class}, not an object" unless answer.is_a?(Hash)

        answer
      end

      # One API call whose answer is a list.
      #
      # @param path [String]
      # @return [Array<Hash>]
      # @raise [ApiError]
      # @raise [MalformedDeploymentError]
      sig { params(path: String).returns(T::Array[JsonHash]) }
      def list(path)
        answer = call(path)
        raise MalformedDeploymentError, "gh api #{path} answered with #{answer.class}, not a list" unless answer.is_a?(Array)

        answer.map do |entry|
          raise MalformedDeploymentError, "gh api #{path} listed #{entry.class}, not an object" unless entry.is_a?(Hash)

          entry
        end
      end

      # @param path [String]
      # @param method [String, nil]
      # @param body [Hash, nil]
      # @return [Object] the parsed answer
      # @raise [ApiError]
      # @raise [MalformedDeploymentError]
      sig { params(path: String, method: T.nilable(String), body: T.nilable(JsonHash)).returns(T.untyped) }
      def call(path, method: nil, body: nil)
        argv = ["api"]
        argv += ["-X", method] if method
        argv += ["--input", "-"] if body
        argv << path
        JSON.parse(@gh.capture(argv, stdin: body && JSON.generate(body)))
      rescue Gh::CommandFailedError => e
        raise ApiError, "the deployment ledger could not be #{method ? "written" : "read"}: #{e.message}"
      rescue JSON::ParserError => e
        raise MalformedDeploymentError, "gh api #{path} answered with something other than JSON: #{e.message}"
      end

      # @param hash [Hash]
      # @param key [String]
      # @return [Object]
      # @raise [MalformedDeploymentError]
      sig { params(hash: JsonHash, key: String).returns(T.untyped) }
      def fetch(hash, key)
        hash.fetch(key) { raise MalformedDeploymentError, "the forge's deployment carries no #{key}" }
      end
    end
  end
end
