# typed: strict
# frozen_string_literal: true

require "dev/cli/command"
require "dev/runner_discovery"
require "dev/stream_follower"

module Dev
  module Cli
    module Builtins
      # `dev runner follow <dir>` — what one slot's job-started hook runs
      # before each job (StreamHook): bring the host to the head of the
      # stream the slot follows and put its `bin` on the job's PATH
      # (StreamFollower). Also a hand run for an operator who wants the
      # head installed now rather than at the next job — `dev runner
      # status` names the command when a head is not installed. The dir
      # names the slot, as the hook's record lives there; the stream is
      # read from it, never given, so a hook and a hand run cannot
      # disagree. A leaf of the `runner` group.
      class RunnerFollowCommand < BuiltinCommand
        extend T::Sig

        # The dir is not an enrollment, or is one whose hook follows no
        # stream: a build host's, or one registered before its project
        # deployed through gh. A RuntimeError so the CLI boundary prints
        # it and exits 1.
        class NoStreamError < RuntimeError; end

        # No dir was given: the hook always names one, a hand run must too.
        class MissingDirError < RuntimeError; end

        # @param discovery [Dev::RunnerDiscovery] reads the slot's record
        # @param follower_factory [Proc] builds the follower on the context's Ui
        sig { params(discovery: Dev::RunnerDiscovery, follower_factory: T.proc.params(ui: Ui).returns(Dev::StreamFollower)).void }
        def initialize(discovery: Dev::RunnerDiscovery.new, follower_factory: ->(ui) { Dev::StreamFollower.new(ui:) })
          super()
          @discovery = discovery
          @follower_factory = follower_factory
        end

        sig { override.returns(String) }
        def desc
          "Install the head of the stream a runner slot follows and export its bin (what the job-started hook runs)"
        end

        sig { override.returns(Command::Category) }
        def category
          Command::Category::Environment
        end

        sig { override.returns(T.nilable(String)) }
        def synopsis
          "<dir>"
        end

        sig { override.returns(T::Array[Cli::Positional]) }
        def positionals
          [Cli::Positional.new("dir", desc: "a runner directory whose hook follows a stream, e.g. ~/actions-runner-agent")]
        end

        # Every local slot that follows a stream, by dir (offline; never gh).
        sig { override.params(words: T::Array[String]).returns(T::Array[String]) }
        def completions(words)
          return [] if words.any? { |word| !word.start_with?("--") }

          @discovery.enrollments.select(&:stream).map(&:display_dir)
        end

        # @raise [MissingDirError] when no dir is given
        # @raise [NoStreamError] when the dir follows no stream
        # @raise [Dev::StreamHeadLookup::NoHeadError] when nothing of the series is deployed
        # @raise [Dev::StreamHeadLookup::HeadNotReleasedError] when the series tag names no release
        # @raise [Dev::StreamHeadLookup::QueryError] when gh cannot be asked
        sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
        def call(args:, context:)
          dir = args.positionals.first
          raise MissingDirError, "dev runner follow: a runner directory is required (dev runner follow #{synopsis})" unless dir

          enrollment = @discovery.at(dir)
          raise NoStreamError, "#{dir} is not a runner enrollment (no .runner record)" unless enrollment

          stream = enrollment.stream
          unless stream
            raise NoStreamError,
              "#{enrollment.display_dir} follows no stream: its jobs run a checkout. A slot follows its project's stream once " \
                "the project deploys through gh and `dev runner register` runs from its checkout."
          end

          @follower_factory.call(context.ui).follow!(stream)
        end
      end
    end
  end
end
