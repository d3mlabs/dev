# typed: strict
# frozen_string_literal: true

require "dev/builtins/plan_verb_command"

module Dev
  module Builtins
    # `dev plan link <n> [<file>] | link <file> [--org]`: attach a plan file to issue
    # #n, or create an issue from a plan file.
    class PlanLinkCommand < PlanVerbCommand
      extend T::Sig

      sig { override.returns(String) }
      def desc = "Attach a plan file to issue #n, or create an issue from a plan file (link <n> [<file>] | link <file>)"

      private

      sig { override.params(accessor: Dev::Plan::Accessor, args: T::Array[String]).void }
      def perform(accessor, args)
        accessor.link(args, out: @out)
      end
    end
  end
end
