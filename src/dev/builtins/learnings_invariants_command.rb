# typed: strict
# frozen_string_literal: true

require "dev/builtins/learnings_verb_command"

module Dev
  module Builtins
    # `dev learnings invariants`: print the always-on org invariants block
    # (the Tier-0 prompt seam).
    class LearningsInvariantsCommand < LearningsVerbCommand
      extend T::Sig

      USAGE = "usage: dev learnings invariants"

      sig { override.returns(String) }
      def desc = "Print the always-on org invariants block (the Tier-0 prompt seam)"

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        raise Dev::Learnings::Accessor::UsageError, USAGE unless args.empty?

        @accessor_factory.call.invariants(out: @out)
      end
    end
  end
end
