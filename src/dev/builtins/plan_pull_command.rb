# typed: strict
# frozen_string_literal: true

require "dev/builtins/plan_verb_command"

module Dev
  module Builtins
    # `dev plan pull <n> [--merge] [--org]`: fetch the issue into the local plan.
    class PlanPullCommand < PlanVerbCommand
      extend T::Sig

      # 3-way merge a diverged local copy instead of refusing.
      MERGE_FLAG = "--merge"
      USAGE = T.let("usage: dev plan pull <n> [#{MERGE_FLAG}] [#{ORG_FLAG}]".freeze, String)

      sig { override.returns(String) }
      def desc = "Fetch the issue into the local plan (pull <n> [--merge] [--org])"

      sig { override.returns(T::Array[Cli::Flag]) }
      def flags = [Cli::Flag.new(MERGE_FLAG), Cli::Flag.new(ORG_FLAG)]

      private

      sig { override.params(accessor: Dev::Plan::Accessor, args: Cli::ParsedArgs).void }
      def perform(accessor, args)
        number = args.positionals.first
        raise Dev::Plan::Accessor::UsageError, USAGE unless args.positionals.size == 1 && number&.match?(/\A\d+\z/)

        accessor.pull(Integer(number), merge: args.flag?(MERGE_FLAG), org: args.flag?(ORG_FLAG), out: @out)
      end
    end
  end
end
