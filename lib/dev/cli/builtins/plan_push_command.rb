# typed: strict
# frozen_string_literal: true

require "dev/cli/builtins/plan_verb_command"

module Dev
  module Cli
    module Builtins
      # `dev plan push [<file>|<n>] [--org]`: update the issue body from the local
      # plan (guarded against clobbering newer remote edits).
      class PlanPushCommand < PlanVerbCommand
        extend T::Sig

        USAGE = T.let("usage: dev plan push [<file>|<n>] [#{ORG_FLAG}]".freeze, String)

        sig { override.returns(String) }
        def desc
          "Update the issue body from the local plan, refusing when the issue moved since the last sync"
        end

        sig { override.returns(T::Array[Cli::Positional]) }
        def positionals
          [
            Cli::Positional.new(
              "plan", optional: true,
              desc: "the plan file, or the number of the issue it is linked to (default: the workspace's sole linked plan)",
            ),
          ]
        end

        sig { override.returns(T::Array[Cli::Flag]) }
        def flags
          [Cli::Flag.new(ORG_FLAG, desc: "resolve an issue number against the org plans repo (a file names its repo itself)")]
        end

        private

        sig { override.params(accessor: Dev::Plan::Accessor, args: Cli::ParsedArgs).void }
        def perform(accessor, args)
          raise Dev::Plan::Accessor::UsageError, USAGE if args.positionals.size > 1

          accessor.push(args.positionals.first, org: args.flag?(ORG_FLAG))
        end
      end
    end
  end
end
