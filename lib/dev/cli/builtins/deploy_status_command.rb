# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/cli/command"
require "dev/lifecycle"

module Dev
  module Cli
    module Builtins
      # `dev deploy status [--release V]`: what each channel carries and from
      # where, read from the deployment ledger on the forge (dev#192, K6) —
      # per channel, its most recent GitHub Deployment: the track, the ref
      # it was made from, when, how it ended and the publisher's receipt,
      # then the builds that shipped with their ids. With `--release V` the
      # same per channel for the release's tag only — the checklist of which
      # channels carry that release. A child of the `deploy` group beside
      # the channels, which is why no channel may be named `status`
      # (ChannelParser).
      #
      # Status is the channel's, not the release's (K6): the release records
      # what the cut made, the ledger what each channel received; `dev
      # release status` would re-conflate the two.
      class DeployStatusCommand < BuiltinCommand
        extend T::Sig

        NAME = "status"
        RELEASE_FLAG = "--release"

        # `status` takes no positional: it reads every channel.
        class UnexpectedArgumentError < ArgumentError; end

        WHEN_FORMAT = "%Y-%m-%d %H:%M UTC"

        # @param channels [Array<Lifecycle::Channel>] the project's channels, in declaration order
        # @param deployments [Lifecycle::GithubDeployments] the ledger
        # @param out [IO, StringIO]
        sig { params(channels: T::Array[Lifecycle::Channel], deployments: Lifecycle::GithubDeployments, out: T.any(IO, StringIO)).void }
        def initialize(channels:, deployments:, out: $stdout)
          super()
          @channels = channels
          @deployments = deployments
          @out = out
        end

        sig { override.returns(String) }
        def desc
          "What each channel carries and from where (status [--release V])"
        end

        sig { override.returns(Command::Category) }
        def category
          Command::Category::Lifecycle
        end

        sig { override.returns(T::Array[Cli::Flag]) }
        def flags
          [Cli::Flag.new(RELEASE_FLAG, takes_value: true, desc: "which channels carry this release (its tag's deployments only)")]
        end

        # @raise [UnexpectedArgumentError]
        # @raise [Lifecycle::ReleaseTag::InvalidVersionError]
        # @raise [Lifecycle::GithubDeployments::Error]
        sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
        def call(args:, context:)
          _ = context
          unless args.positionals.empty?
            raise UnexpectedArgumentError, "deploy status reads every channel and takes no build: got #{args.positionals.map(&:inspect).join(", ")}"
          end

          version = args.value(RELEASE_FLAG)
          tag = version && Lifecycle::ReleaseTag.new(version)
          width = @channels.map { |channel| channel.name.length }.max || 0
          @channels.each do |channel|
            latest = @deployments.latest(channel: channel.name, ref: tag&.name)
            if latest.nil?
              @out.puts "#{channel.name.ljust(width)}  #{absence(tag)}"
              next
            end

            @out.puts "#{channel.name.ljust(width)}  #{headline(latest)}"
            latest.record.builds.each { |shipped| @out.puts "#{" " * width}  #{shipped}" }
          end
        end

        private

        # @param tag [Lifecycle::ReleaseTag, nil]
        # @return [String] the line for a channel with nothing recorded
        sig { params(tag: T.nilable(Lifecycle::ReleaseTag)).returns(String) }
        def absence(tag)
          tag ? "– #{tag} not deployed" : "– nothing deployed"
        end

        # @param deployment [Lifecycle::Deployment]
        # @return [String] one line: how it ended, the track, the ref, when, and what the publisher said
        sig { params(deployment: Lifecycle::Deployment).returns(String) }
        def headline(deployment)
          record = deployment.record
          provenance = "#{record.track} from #{record.ref} at #{deployment.created_at.utc.strftime(WHEN_FORMAT)}"
          state = record.state
          if state.success?
            "✓ #{provenance} — #{record.description}"
          elsif state.failed?
            "✗ #{provenance} — failed: #{record.description}"
          else
            "… #{state} #{provenance}"
          end
        end
      end
    end
  end
end
