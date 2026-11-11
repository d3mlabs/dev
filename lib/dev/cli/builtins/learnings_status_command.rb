# typed: strict
# frozen_string_literal: true

require "dev/cli/builtins/learnings_verb_command"

module Dev
  module Cli
    module Builtins
      # `dev learnings status`: the configured knowledge repo, cache
      # location/age, and what is rendered and linked.
      class LearningsStatusCommand < LearningsVerbCommand
        extend T::Sig

        USAGE = "usage: dev learnings status"

        sig { override.returns(String) }
        def desc
          "Show the configured knowledge repo, cache location/age, what's rendered and linked"
        end

        sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
        def call(args:, context:)
          raise Dev::Learnings::Accessor::UsageError, USAGE unless args.positionals.empty?

          @accessor_factory.call(context.ui).status
        end
      end
    end
  end
end
