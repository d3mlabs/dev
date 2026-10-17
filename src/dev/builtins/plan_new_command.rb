# typed: strict
# frozen_string_literal: true

require "dev/builtins/plan_verb_command"

module Dev
  module Builtins
    # `dev plan new "<title>" [--blank] [--org]`: create a templated issue (canonical
    # from birth) and the linked local plan.
    class PlanNewCommand < PlanVerbCommand
      extend T::Sig

      # Scaffold only the H1, no template body.
      BLANK_FLAG = "--blank"
      USAGE = T.let("usage: dev plan new \"<title>\" [#{BLANK_FLAG}] [#{ORG_FLAG}]".freeze, String)

      sig { override.returns(String) }
      def desc = "Create a templated issue + linked local plan (new \"<title>\" [--blank] [--org])"

      sig { override.returns(T::Array[Cli::Flag]) }
      def flags = [Cli::Flag.new(BLANK_FLAG), Cli::Flag.new(ORG_FLAG)]

      private

      sig { override.params(accessor: Dev::Plan::Accessor, args: Cli::ParsedArgs).void }
      def perform(accessor, args)
        title = args.positionals.first
        raise Dev::Plan::Accessor::UsageError, USAGE if title.nil? || title.empty? || args.positionals.size > 1

        accessor.new_plan(title, blank: args.flag?(BLANK_FLAG), org: args.flag?(ORG_FLAG), out: @out)
      end
    end
  end
end
