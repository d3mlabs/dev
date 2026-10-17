# typed: strict
# frozen_string_literal: true

require "dev/builtins/plan_verb_command"

module Dev
  module Builtins
    # `dev plan init`: scaffold/update the repo's plan template mirror.
    class PlanInitCommand < PlanVerbCommand
      extend T::Sig

      sig { override.returns(String) }
      def desc = "Scaffold/update the repo's plan template mirror"

      private

      sig { override.params(accessor: Dev::Plan::Accessor, args: Cli::ParsedArgs).void }
      def perform(accessor, args)
        raise Dev::Plan::Accessor::UsageError, "usage: dev plan init" unless args.positionals.empty?

        accessor.init(out: @out)
      end
    end
  end
end
