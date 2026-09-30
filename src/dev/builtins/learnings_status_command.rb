# typed: strict
# frozen_string_literal: true

require "dev/builtins/learnings_verb_command"

module Dev
  module Builtins
    # `dev learnings status`: the configured knowledge repo, cache
    # location/age, and what is rendered and linked.
    class LearningsStatusCommand < LearningsVerbCommand
      extend T::Sig

      USAGE = "usage: dev learnings status"

      sig { override.returns(String) }
      def desc = "Show the configured knowledge repo, cache location/age, what's rendered and linked"

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        raise Dev::Learnings::Accessor::UsageError, USAGE unless args.empty?

        @accessor_factory.call.status(out: @out)
      end
    end
  end
end
