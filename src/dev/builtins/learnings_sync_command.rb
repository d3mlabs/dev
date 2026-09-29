# typed: strict
# frozen_string_literal: true

require "dev/builtins/learnings_verb_command"

module Dev
  module Builtins
    # `dev learnings sync`: refresh the whole read path now (blocking) —
    # knowledge repo cache, skill links, invariants render.
    class LearningsSyncCommand < LearningsVerbCommand
      extend T::Sig

      USAGE = "usage: dev learnings sync"

      sig { override.returns(String) }
      def desc = "Refresh the whole read path now: knowledge repo cache, skill links, invariants render"

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        raise Dev::Learnings::Accessor::UsageError, USAGE unless args.empty?

        @accessor_factory.call.sync(out: @out)
      end
    end
  end
end
