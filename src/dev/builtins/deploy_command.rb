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
    # `--dry-run`; `after` reports each artifact shipped (the receipt as a
    # GitHub Deployment is dev#423).
    class DeployCommand < LifecycleCommand
      extend T::Sig

      DRY_RUN_FLAG = "--dry-run"

      # The channel's protocol has no placement bound: the lock could not
      # be read at load (the root said so and kept the tree so the re-lock
      # stays reachable).
      class UnboundChannelError < RuntimeError; end

      # What `before` resolves and the seam and `after` read.
      class DeployEnv < T::Struct
        const :channel, Lifecycle::Channel
        const :selection, DeploySelector::Selection
        const :publisher, Lifecycle::Publisher
        const :dry_run, T::Boolean
      end

      Env = type_member { { fixed: DeployEnv } }

      # @param channel [Lifecycle::Channel] the destination this command ships to
      # @param selector [DeploySelector] argv → the artifacts
      # @param publisher [Lifecycle::Publisher] the channel's protocol
      # @param resolver [DispatchResolver] where the protocol runs
      # @param placement [Placement, nil] the protocol's bound environment;
      #   nil when the lock could not be read at load
      # @param out [IO, StringIO]
      sig do
        params(
          channel: Lifecycle::Channel,
          selector: DeploySelector,
          publisher: Lifecycle::Publisher,
          resolver: DispatchResolver,
          placement: T.nilable(Placement),
          out: T.any(IO, StringIO),
        ).void
      end
      def initialize(channel:, selector:, publisher:, resolver:, placement:, out: $stdout)
        super()
        @channel = channel
        @selector = selector
        @publisher = publisher
        @resolver = resolver
        @placement = placement
        @out = out
      end

      sig { override.returns(String) }
      def desc = @channel.desc

      sig { override.returns(T::Array[Cli::Flag]) }
      def flags
        DeploySelector::FLAGS + [Cli::Flag.new(DRY_RUN_FLAG, desc: "select and report, ship nothing")]
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

        env.publisher.publish(env.selection.artifacts, channel: env.channel)
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
      end

      private

      # @return [Placement]
      # @raise [UnboundChannelError]
      sig { returns(Placement) }
      def placement!
        @placement || raise(UnboundChannelError,
          "`deploy #{@channel}` has no environment bound: the lock could not be read at load — re-lock it (dev deps update) and retry")
      end
    end
  end
end
