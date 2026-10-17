# typed: strict
# frozen_string_literal: true

require "dev/builtins/plan_verb_command"

module Dev
  module Builtins
    # `dev plan pull <n> [--merge] [--org]`: fetch the issue into the local plan.
    class PlanPullCommand < PlanVerbCommand
      extend T::Sig

      sig { override.returns(String) }
      def desc = "Fetch the issue into the local plan (pull <n> [--merge] [--org])"

      sig { override.returns(T::Array[Cli::Flag]) }
      def flags = [Cli::Flag.new(Dev::Plan::Accessor::MERGE_FLAG), Cli::Flag.new(Dev::Plan::Accessor::ORG_FLAG)]

      private

      sig { override.params(accessor: Dev::Plan::Accessor, args: Cli::ParsedArgs).void }
      def perform(accessor, args)
        accessor.pull(args.words, out: @out)
      end
    end
  end
end
