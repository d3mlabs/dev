# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/command"
require "dev/deploy_selector"
require "dev/dispatch"
require "dev/dispatch_resolver"
require "dev/lifecycle"
require "dev/lifecycle_executor"
require_relative "../cli/flag_vocabulary"
require_relative "deploy_command"
require_relative "deploy_status_command"

module Dev
  module Builtins
    # `dev deploy`, the node heading the channels (dev#192, K4; dev#425):
    # `dev deploy <channel> …` reaches a child (DeployCommand) and
    # `dev deploy status` the ledger's reader (DeployStatusCommand), as
    # with any node; what the node itself runs is the **fan-out** —
    # `dev deploy --release <version>` with no channel named ships the
    # release to every channel in turn, in declaration order, each as
    # `dev deploy <channel> --release <version>` run as itself through the
    # LifecycleExecutor (the way `release` runs `package`): the same
    # selection, dispatch, record and report per channel, headed by the
    # invocation it stands for. The first channel that refuses — a release
    # carrying no archive it accepts, a protocol that fails — ends the
    # fan-out there, the earlier channels deployed; the error names the
    # channel, and the fix is to name the channels to ship to. Nothing
    # fans out from the store: working artifacts are one channel's
    # business at a time, so bare `dev deploy` is refused with the shape
    # of the verb, as is a word that names no channel.
    #
    # The flags are the ones every channel reads the same way — the
    # release, `--dry-run`, the runner — carried to each child by their
    # spelling; `--config`, `--allow-stale` and `--force` qualify one
    # channel's selection (a config one channel's builds lack would refuse
    # the whole fan-out) and are not declared here. The dispatch is native:
    # each channel resolves its own.
    class DeployAllCommand < LifecycleCommand
      extend T::Sig

      NAME = DeployCommand::NAME

      # The flags every channel shares: the release and the rehearsal.
      FLAGS = T.let(
        DeployCommand::SELECTION_FLAGS.select { |flag| [DeploySelector::RELEASE_FLAG, DeployCommand::DRY_RUN_FLAG].include?(flag.name) }.freeze,
        T::Array[Cli::Flag],
      )

      # Bare `dev deploy`, or with flags but no `--release`: the store
      # ships one channel at a time, so there is nothing to fan out.
      class NoChannelError < ArgumentError; end

      # A positional that is no channel's name (`dev deploy foo`).
      class UnknownChannelError < ArgumentError; end

      # What `before` resolves: the release, the words each channel runs
      # with, and whether they ship.
      class FanOutEnv < T::Struct
        const :tag, Lifecycle::ReleaseTag
        const :words, T::Array[String]
        const :dry_run, T::Boolean
      end

      Env = type_member { { fixed: FanOutEnv } }

      # @param channels [Hash{String => DeployCommand}] one per channel, in declaration order
      # @param status [DeployStatusCommand] the ledger's reader, the last child
      # @param executor [LifecycleExecutor] runs each channel as itself
      # @param vocabulary [Cli::FlagVocabulary] parses the carried words against each channel's flags
      # @param out [IO, StringIO]
      sig do
        params(
          channels: T::Hash[String, DeployCommand],
          status: DeployStatusCommand,
          executor: LifecycleExecutor,
          vocabulary: Cli::FlagVocabulary,
          out: T.any(IO, StringIO),
        ).void
      end
      def initialize(channels:, status:, executor: LifecycleExecutor.new, vocabulary: Cli::FlagVocabulary.new, out: $stdout)
        super(children: T.let(channels.merge(DeployStatusCommand::NAME => status), T::Hash[String, Command]))
        @channels = channels
        @executor = executor
        @vocabulary = vocabulary
        @out = out
      end

      sig { override.returns(String) }
      def desc
        "Ship archives to a channel (deploy <channel> [BUILD] [--config C] [--release V] [--allow-stale] [--force] [--dry-run] [--runner L])\n" \
          "Selects from the store of the host it runs on (testing track), or with --release V from that release's verified archives " \
          "(live track); never builds. Each channel lists the builds it accepts and its protocol. " \
          "`deploy --release V` with no channel ships the release to every channel in turn; " \
          "`deploy status [--release V]` reads what each channel carries."
      end

      sig { override.returns(T::Array[Cli::Flag]) }
      def flags = FLAGS + DispatchResolver::FLAGS

      sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).returns(Dispatch::Outcome[FanOutEnv]) }
      def before(args:, context:)
        _ = context
        unless args.positionals.empty?
          raise UnknownChannelError,
            "'#{T.must(args.positionals.first)}' is not a channel (channels: #{@channels.keys.join(", ")}); `dev deploy <channel> [BUILD]`"
        end

        version = args.value(DeploySelector::RELEASE_FLAG)
        if version.nil?
          raise NoChannelError,
            "deploy ships to one channel at a time from the store — `dev deploy <channel> [BUILD]` (channels: #{@channels.keys.join(", ")}); " \
              "only `dev deploy #{DeploySelector::RELEASE_FLAG} <version>` ships to every channel"
        end

        tag = Lifecycle::ReleaseTag.new(version)
        words = args.spelling(flags)
        # Each channel resolves its own dispatch (K10), so this one is
        # native and its invocation is never spoken to a host.
        Dispatch::Native.new.dispatch(Lifecycle::VerbInvocation.new(words: [NAME, *words])) do
          FanOutEnv.new(tag:, words:, dry_run: args.flag?(DeployCommand::DRY_RUN_FLAG))
        end
      end

      sig { override.params(env: FanOutEnv, context: ExecutionContext).void }
      def seam(env, context:)
        @channels.each do |name, channel|
          @out.puts "#{NAME} #{name} #{env.words.join(" ")}"
          @executor.execute(channel, args: @vocabulary.parse(channel, path: [NAME, name], args: env.words), context:)
        end
      end

      sig { override.params(env: FanOutEnv, context: ExecutionContext).void }
      def after(env, context:)
        _ = context
        verb = env.dry_run ? "would ship" : "shipped"
        @out.puts "#{env.tag} #{verb} to #{@channels.size == 1 ? "1 channel" : "#{@channels.size} channels"}: #{@channels.keys.join(", ")}"
      end
    end
  end
end
