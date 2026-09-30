# typed: strict
# frozen_string_literal: true

require "dev/builtins/plan_verb_command"

module Dev
  module Builtins
    # `dev plan new "<title>" [--blank] [--org]`: create a templated issue (canonical
    # from birth) and the linked local plan.
    class PlanNewCommand < PlanVerbCommand
      extend T::Sig

      sig { override.returns(String) }
      def desc = "Create a templated issue + linked local plan (new \"<title>\" [--blank] [--org])"

      private

      sig { override.params(accessor: Dev::Plan::Accessor, args: T::Array[String]).void }
      def perform(accessor, args)
        accessor.new_plan(args, out: @out)
      end
    end
  end
end
