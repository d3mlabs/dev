# typed: strict
# frozen_string_literal: true

require "dev/builtins/plan_verb_command"

module Dev
  module Builtins
    # `dev plan push [<file>|<n>] [--org]`: update the issue body from the local
    # plan (guarded against clobbering newer remote edits).
    class PlanPushCommand < PlanVerbCommand
      extend T::Sig

      USAGE = T.let("usage: dev plan push [<file>|<n>] [#{ORG_FLAG}]".freeze, String)

      sig { override.returns(String) }
      def desc = "Update the issue body from the local plan, guarded (push [<file>|<n>] [--org])"

      sig { override.returns(T::Array[Cli::Flag]) }
      def flags = [Cli::Flag.new(ORG_FLAG)]

      private

      sig { override.params(accessor: Dev::Plan::Accessor, args: Cli::ParsedArgs).void }
      def perform(accessor, args)
        raise Dev::Plan::Accessor::UsageError, USAGE if args.positionals.size > 1

        accessor.push(args.positionals.first, org: args.flag?(ORG_FLAG), out: @out)
      end
    end
  end
end
