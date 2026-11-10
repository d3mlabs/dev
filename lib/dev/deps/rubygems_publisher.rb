# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/credentials"
require "dev/lifecycle/channel"
require "dev/lifecycle/publisher"
require "dev/lifecycle/receipt"
require "dev/lifecycle/shell"
require "dev/lifecycle/shipment"
require "dev/lifecycle/track"

module Dev
  module Deps
    # The write side of the gems entry (dev#192 K5, dev#428): `gem push` of
    # each shipped `.gem` to rubygems.org — the store the project's gems
    # are installed from, publishable because the project already depends
    # on it (ADR-0010). Every project whose lock pins gems gets the
    # `deploy rubygems` channel with no dev.yml line; its first consumers
    # are the org's gem repos, whose one target packages the gem itself.
    #
    # rubygems.org has a single track: a pushed version is live the moment
    # it lands and its number can never be reused (a yank hides it, it does
    # not free it). So the testing track is **refused** rather than mapped
    # — a working artifact from the store has nowhere to go here, a
    # release's archive has (`dev deploy rubygems --release <v>`). The API
    # key is the publisher's own: the Credentials provider under
    # `rubygems api_key` (`GEM_HOST_API_KEY` in the environment overrides
    # it, the variable `gem` itself reads), handed to `gem push` through
    # its env and never on argv. The archive is read-only input — `gem
    # push` uploads the file as it is — and nothing lands in the scratch.
    #
    # The project root (where `gem` runs), the shell and the credential
    # provider are fixed for a checkout and constructor-owned; the
    # shipments are per call.
    class RubygemsPublisher
      extend T::Sig
      include Lifecycle::Publisher

      # Asked to ship a working artifact: rubygems.org has no track that
      # is not live.
      class TestingTrackUnsupportedError < RuntimeError; end

      # A shipped archive is not a `.gem`: the target's packager does not
      # produce what this channel uploads.
      class NotAGemError < RuntimeError; end

      # `gem push` ended other than with exit 0.
      class PushFailedError < RuntimeError; end

      # The one destination this channel knows, passed to `gem push`
      # explicitly so a gemspec's `allowed_push_host` elsewhere is a
      # refusal, never a silent redirect.
      HOST = "https://rubygems.org"
      EXTENSION = ".gem"
      CREDENTIAL_NAMESPACE = "rubygems"
      CREDENTIAL_KEY = "api_key"
      # The variable `gem push` reads its key from, so the operator's own
      # environment overrides the stored credential the way it does for gem.
      API_KEY_ENV_VAR = "GEM_HOST_API_KEY"
      API_KEY_URL = "https://rubygems.org/profile/api_keys/new"

      # @param project_root [Pathname] where `gem push` runs
      # @param shell [Lifecycle::Shell] the process boundary
      # @param credentials [#resolve] the credential provider (default: Dev::Credentials)
      sig { params(project_root: Pathname, shell: Lifecycle::Shell, credentials: T.untyped).void }
      def initialize(project_root:, shell: Lifecycle::Shell.new, credentials: Credentials)
        @project_root = project_root
        @shell = shell
        @credentials = credentials
      end

      # Push every shipped gem, in order. The whole set is checked before
      # the first upload: a refusal after one gem went live would leave a
      # release half-published with no way back.
      #
      # @param shipments [Array<Lifecycle::Shipment>] each archive a `.gem`
      # @param channel [Lifecycle::Channel] for the messages
      # @param track [Lifecycle::Track] must be live
      # @param scratch [Pathname] unused: nothing is materialised
      # @return [Lifecycle::Receipt] the gems pushed, by file name
      # @raise [TestingTrackUnsupportedError]
      # @raise [NotAGemError]
      # @raise [PushFailedError] at the first gem rubygems.org refuses
      # @raise [Credentials::MissingCredentialError] on a non-interactive miss of the API key
      # @raise [Lifecycle::Shell::SpawnError]
      sig do
        override.params(
          shipments: T::Array[Lifecycle::Shipment], channel: Lifecycle::Channel, track: Lifecycle::Track, scratch: Pathname,
        ).returns(Lifecycle::Receipt)
      end
      def publish(shipments, channel:, track:, scratch:)
        _ = scratch
        refuse_testing!(track, channel)
        shipments.each { |shipment| assert_gem!(shipment, channel) }
        env = { API_KEY_ENV_VAR => api_key }
        shipments.each { |shipment| push(shipment, env:) }
        Lifecycle::Receipt.new(summary: "pushed to #{HOST}: #{shipments.map { |shipment| shipment.archive.basename }.join(", ")}")
      end

      # The declaration as `dev help` renders it.
      sig { returns(String) }
      def to_s
        "gem push"
      end

      private

      # @param track [Lifecycle::Track]
      # @param channel [Lifecycle::Channel]
      # @raise [TestingTrackUnsupportedError]
      sig { params(track: Lifecycle::Track, channel: Lifecycle::Channel).void }
      def refuse_testing!(track, channel)
        return if track.live?

        raise TestingTrackUnsupportedError,
          "channel '#{channel}' ships to rubygems.org, which has no testing track: a pushed version is live and can " \
            "never be reused — cut a release and deploy that (`dev release <version>`, then " \
            "`dev deploy #{channel} --release <version>`)"
      end

      # @param shipment [Lifecycle::Shipment]
      # @param channel [Lifecycle::Channel]
      # @raise [NotAGemError]
      sig { params(shipment: Lifecycle::Shipment, channel: Lifecycle::Channel).void }
      def assert_gem!(shipment, channel)
        return if shipment.archive.extname == EXTENSION

        raise NotAGemError,
          "channel '#{channel}' uploads gems, and #{shipment.name}'s archive is #{shipment.archive.basename} — give its " \
            "target a packager that produces a .gem (`packager: as-is` over a `build:` running `gem build`)"
      end

      # @param shipment [Lifecycle::Shipment]
      # @param env [Hash{String => String}] the API key, as `gem` reads it
      # @raise [PushFailedError]
      # @raise [Lifecycle::Shell::SpawnError]
      sig { params(shipment: Lifecycle::Shipment, env: T::Hash[String, String]).void }
      def push(shipment, env:)
        status = @shell.run(["gem", "push", "--host", HOST, shipment.archive.to_s], chdir: @project_root, env:)
        return if status.success?

        raise PushFailedError, "gem push #{shipment.archive.basename} (#{shipment}) #{Lifecycle::Shell.describe(status)}"
      end

      # The API key through the provider's chain: the environment, the
      # stored credential, a prompt when interactive.
      #
      # @return [String]
      # @raise [Credentials::MissingCredentialError]
      sig { returns(String) }
      def api_key
        @credentials.resolve(
          namespace: CREDENTIAL_NAMESPACE, key: CREDENTIAL_KEY, env_var: API_KEY_ENV_VAR,
          prompt_label: "rubygems.org API key with push scope", create_url: API_KEY_URL,
        )
      end
    end
  end
end
