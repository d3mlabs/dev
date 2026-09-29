# typed: strict
# frozen_string_literal: true

require "dev/builtins/plan_verb_command"

module Dev
  module Builtins
    # `dev plan status`: the sync state of every linked plan.
    class PlanStatusCommand < PlanVerbCommand
      extend T::Sig

      sig { override.returns(String) }
      def desc = "Sync state of all linked plans"

      private

      sig { override.params(accessor: Dev::Plan::Accessor, args: T::Array[String]).void }
      def perform(accessor, args)
        raise Dev::Plan::Accessor::UsageError, "usage: dev plan status" unless args.empty?

        accessor.status(out: @out)
      end
    end
  end
end
