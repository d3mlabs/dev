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

      sig { override.returns(T::Array[Cli::Flag]) }
      def flags = [Cli::Flag.new(Dev::Plan::Accessor::ORG_FLAG)]

      private

      sig { override.params(accessor: Dev::Plan::Accessor, args: Cli::ParsedArgs).void }
      def perform(accessor, args)
        accessor.link(args.words, out: @out)
      end
    end
  end
end
