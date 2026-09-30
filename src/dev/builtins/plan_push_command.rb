# typed: strict
# frozen_string_literal: true

require "dev/builtins/plan_verb_command"

module Dev
  module Builtins
    # `dev plan push [<file>|<n>] [--org]`: update the issue body from the local
    # plan (guarded against clobbering newer remote edits).
    class PlanPushCommand < PlanVerbCommand
      extend T::Sig

      sig { override.returns(String) }
      def desc = "Update the issue body from the local plan, guarded (push [<file>|<n>] [--org])"

      private

      sig { override.params(accessor: Dev::Plan::Accessor, args: T::Array[String]).void }
      def perform(accessor, args)
        accessor.push(args, out: @out)
      end
    end
  end
end
