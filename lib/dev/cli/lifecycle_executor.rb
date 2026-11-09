# typed: strict
# frozen_string_literal: true

require_relative "parsed_args"
require_relative "command"
require_relative "dispatch"
require_relative "execution_context"

module Dev
  module Cli
    # The template strategy for a lifecycle verb (dev#192, K1b): before →
    # seam → after, in this process, interpreting the Dispatch outcome
    # `before` returns. Run(env): the seam and then `after`, both with that
    # env and nothing of argv. Done: the dispatch ran the verb on another
    # host, so nothing of the stage is left here. A seam that raises ends
    # the run before `after` — the error bubbles to the CLI boundary, which
    # is what makes a stamp written in `after` mean "the seam succeeded".
    #
    # Nothing here spawns or waits: the seams are the verbs' own ports
    # (Lifecycle::Shell is their spawn-and-wait boundary), so this strategy
    # holds no process collaborator and is wired the same in every
    # composite.
    class LifecycleExecutor
      extend T::Sig

      # Run one verb end to end.
      #
      # @param command [LifecycleCommand]
      # @param args [Cli::ParsedArgs] parsed against the verb's `flags`;
      #   consumed by `before`, never seen by the seam
      # @param context [ExecutionContext]
      # @return [void]
      sig { params(command: LifecycleCommand[T.untyped], args: Cli::ParsedArgs, context: ExecutionContext).void }
      def execute(command, args:, context:)
        outcome = command.before(args:, context:)
        case outcome
        when Dispatch::Outcome::Run
          command.seam(outcome.env, context:)
          command.after(outcome.env, context:)
        when Dispatch::Outcome::Done
          nil
        else
          # simplecov:disable — the sealed outcome has no third shape;
          # T.absurd keeps the static proof.
          T.absurd(outcome)
          # simplecov:enable
        end
      end
    end
  end
end
