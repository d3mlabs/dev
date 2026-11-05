# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/command"
require "dev/deploy_selector"
require "dev/dispatch"
require "dev/dispatch_resolver"
require "dev/lifecycle"
require "dev/placement"

module Dev
  module Builtins
    # `dev deploy <channel> [BUILD] [--config C] [--allow-stale] [--force]
    # [--dry-run]`: ship artifacts from the store to one channel (dev#192,
    # K4, K5). One instance per channel, each a child of the `deploy`
    # group, so a channel is a subcommand with its own help, flags and
    # completion. `deploy` never builds: what ships is selected from the
    # store (DeploySelector — the accept set narrowed by BUILD, one
    # artifact per accepted platform, `--config` choosing among configs),
    # refused when missing, stale without `--allow-stale`, or outside the
    # accept set without `--force`.
    #
    # The stage: `before` resolves where the protocol runs (the channel's
    # `run:` environment under the host rule), reads the tree once (what
    # staleness is read against) and consumes the argv into the selection;
    # the seam is the publisher — the `run:` once per archive with
    # `DEV_ARTIFACT` and the manifest's keys in its env — skipped under
    # `--dry-run`; `after` reports each artifact shipped and records the
    # deploy as a GitHub Deployment (K6): the channel as its environment,
    # the artifacts' commit as its ref, the builds and the track in its
    # payload, the publisher's receipt in its `success` status. A seam
    # that raises is recorded too, as a `failure` carrying the error —
    # best-effort, since the protocol's own error is the one the operator
    # must see — before the error bubbles. The receipt crosses from the
    # seam to `after` through the env: the template's one channel between
    # the stages.
    class DeployCommand < LifecycleCommand
      extend T::Sig

      DRY_RUN_FLAG = "--dry-run"

      # The channel's protocol has no placement bound: the lock could not
      # be read at load (the root said so and kept the tree so the re-lock
      # stays reachable).
      class UnboundChannelError < RuntimeError; end

      # `after` ran before the seam handed back a receipt — a wiring bug.
      class NoReceiptError < StandardError; end

      # The archives shipped, but the ledger refused the record (a ref the
      # forge does not have, a token without `deployments: write`, an
      # artifact packaged outside a checkout). The deploy happened; the
      # message says so and carries the ledger's reason.
      class NotRecordedError < RuntimeError; end

      # What `before` resolves; the seam fills `receipt` for `after`.
      class DeployEnv
        extend T::Sig

        sig { returns(Lifecycle::Channel) }
        attr_reader :channel

        sig { returns(DeploySelector::Selection) }
        attr_reader :selection

        sig { returns(Lifecycle::Publisher) }
        attr_reader :publisher

        sig { returns(T::Boolean) }
        attr_reader :dry_run

        # @return [Lifecycle::Receipt, nil] what the publisher said
        sig { returns(T.nilable(Lifecycle::Receipt)) }
        attr_accessor :receipt

        sig do
          params(channel: Lifecycle::Channel, selection: DeploySelector::Selection, publisher: Lifecycle::Publisher, dry_run: T::Boolean).void
        end
        def initialize(channel:, selection:, publisher:, dry_run:)
          @channel = channel
          @selection = selection
          @publisher = publisher
          @dry_run = dry_run
          @receipt = T.let(nil, T.nilable(Lifecycle::Receipt))
        end

        # @return [Lifecycle::Receipt]
        # @raise [NoReceiptError]
        sig { returns(Lifecycle::Receipt) }
        def receipt!
          @receipt || raise(NoReceiptError, "deploy #{@channel}: `after` ran before the seam handed back a receipt")
        end
      end

      Env = type_member { { fixed: DeployEnv } }

      # @param channel [Lifecycle::Channel] the destination this command ships to
      # @param selector [DeploySelector] argv → the artifacts
      # @param publisher [Lifecycle::Publisher] the channel's protocol
      # @param resolver [DispatchResolver] where the protocol runs
      # @param placement [Placement, nil] the protocol's bound environment;
      #   nil when the lock could not place it at load
      # @param deployments [Lifecycle::GithubDeployments] the ledger each deploy is recorded in
      # @param out [IO, StringIO]
      # @param err [IO, StringIO] where a failure record that itself failed is reported
      sig do
        params(
          channel: Lifecycle::Channel,
          selector: DeploySelector,
          publisher: Lifecycle::Publisher,
          resolver: DispatchResolver,
          placement: T.nilable(Placement),
          deployments: Lifecycle::GithubDeployments,
          out: T.any(IO, StringIO),
          err: T.any(IO, StringIO),
        ).void
      end
      def initialize(channel:, selector:, publisher:, resolver:, placement:, deployments:, out: $stdout, err: $stderr)
        super()
        @channel = channel
        @selector = selector
        @publisher = publisher
        @resolver = resolver
        @placement = placement
        @deployments = deployments
        @out = out
        @err = err
      end

      sig { override.returns(String) }
      def desc = @channel.desc

      sig { override.returns(T::Array[Cli::Flag]) }
      def flags
        DeploySelector::FLAGS + [Cli::Flag.new(DRY_RUN_FLAG, desc: "select and report, ship nothing, record nothing")]
      end

      sig { override.returns(T.nilable(Placement)) }
      attr_reader :placement

      # The accept set, expanded, and where the protocol comes from — what
      # `dev help deploy` says of each channel.
      sig { override.returns(T::Array[String]) }
      def details
        ["Accepts: #{@channel.builds.map(&:name).join(", ")}", "Protocol: #{@channel.publisher}"]
      end

      # Every name the positional admits: the accept patterns and the
      # builds they span, in accept order.
      sig { override.params(words: T::Array[String]).returns(T::Array[String]) }
      def completions(words)
        _ = words
        @channel.accepts.flat_map { |pattern| [pattern.name] + pattern.builds.map(&:name) }.uniq
      end

      sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).returns(Dispatch::Outcome[DeployEnv]) }
      def before(args:, context:)
        dispatch = @resolver.resolve(placement!, subject: "deploy #{@channel}")
        state = Lifecycle::GitState.read(context.project!.root)
        env = DeployEnv.new(
          channel: @channel,
          selection: @selector.select(args, state:),
          publisher: @publisher,
          dry_run: args.flag?(DRY_RUN_FLAG),
        )
        dispatch.dispatch(env)
      end

      sig { override.params(env: DeployEnv, context: ExecutionContext).void }
      def seam(env, context:)
        _ = context
        return if env.dry_run

        env.receipt = env.publisher.publish(env.selection.artifacts, channel: env.channel)
      rescue StandardError => e
        record_failure(env, e)
        raise
      end

      sig { override.params(env: DeployEnv, context: ExecutionContext).void }
      def after(env, context:)
        _ = context
        verb = env.dry_run ? "would deploy" : "deployed"
        env.selection.artifacts.each do |artifact|
          line = "#{verb} #{artifact.name} (#{artifact.manifest.build_id}) → #{env.channel}: #{artifact.archive}"
          line += " — stale, shipped under #{DeploySelector::ALLOW_STALE_FLAG}" if env.selection.stale.include?(artifact)
          @out.puts line
        end
        return if env.dry_run

        deployments = records(env, state: Lifecycle::DeploymentState::Success, description: env.receipt!.summary)
          .map { |record| @deployments.record(record) }
        @out.puts "recorded as GitHub Deployment #{deployments.map { |deployment| "##{deployment.id}" }.join(", ")} " \
                  "(#{env.selection.track} track) → #{T.must(deployments.first).url}"
      rescue Lifecycle::GithubDeployments::Error, Lifecycle::DeploymentRecord::UnknownRefError => e
        raise NotRecordedError, "deployed to #{env.channel}, but the deploy was not recorded: #{e.message}"
      end

      private

      # @return [Placement]
      # @raise [UnboundChannelError]
      sig { returns(Placement) }
      def placement!
        @placement || raise(UnboundChannelError,
          "`deploy #{@channel}` has no environment bound: the lock could not place it at load — re-lock it (dev deps update) and retry")
      end

      # The records this deploy makes, one per commit the artifacts came
      # from.
      #
      # @param env [DeployEnv]
      # @param state [Lifecycle::DeploymentState]
      # @param description [String]
      # @return [Array<Lifecycle::DeploymentRecord>]
      # @raise [Lifecycle::DeploymentRecord::UnknownRefError]
      sig { params(env: DeployEnv, state: Lifecycle::DeploymentState, description: String).returns(T::Array[Lifecycle::DeploymentRecord]) }
      def records(env, state:, description:)
        Lifecycle::DeploymentRecord.of(env.selection.artifacts, channel: env.channel.name, track: env.selection.track, state:, description:)
      end

      # Record a seam that raised as a failed deploy. Best-effort: the
      # protocol's error is what the operator must see, so a ledger that
      # cannot be written is reported on stderr and never replaces it.
      #
      # @param env [DeployEnv]
      # @param error [StandardError] what the seam raised
      # @return [void]
      sig { params(env: DeployEnv, error: StandardError).void }
      def record_failure(env, error)
        records(env, state: Lifecycle::DeploymentState::Failure, description: error.message).each { |record| @deployments.record(record) }
      rescue Lifecycle::GithubDeployments::Error, Lifecycle::DeploymentRecord::UnknownRefError => e
        @err.puts "dev: the failed deploy #{env.channel} was not recorded: #{e.message}"
      end
    end
  end
end
