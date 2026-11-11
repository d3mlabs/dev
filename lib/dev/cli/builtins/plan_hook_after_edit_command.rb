# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/cli/builtins/plan_verb_command"

module Dev
  module Cli
    module Builtins
      # `dev plan hook-after-edit`: the Cursor `afterFileEdit` hook
      # (registered by a participating repo's .cursor/hooks.json): reads the
      # hook payload from stdin and auto-pushes the edited file when it is a
      # linked plan, else no-ops. Plumbing, so hidden from the listings.
      class PlanHookAfterEditCommand < PlanVerbCommand
        extend T::Sig

        sig { params(accessor_factory: AccessorFactory, input: T.any(IO, StringIO)).void }
        def initialize(accessor_factory: DEFAULT_ACCESSOR_FACTORY, input: $stdin)
          super(accessor_factory:)
          @input = input
        end

        sig { override.returns(String) }
        def desc
          "Cursor afterFileEdit hook: auto-push an edited linked plan (payload on stdin)"
        end

        sig { override.returns(T::Boolean) }
        def hidden?
          true
        end

        private

        sig { override.params(accessor: Dev::Plan::Accessor, args: Cli::ParsedArgs).void }
        def perform(accessor, args)
          raise Dev::Plan::Accessor::UsageError, "usage: dev plan hook-after-edit" unless args.positionals.empty?

          accessor.hook_after_edit(@input)
        end
      end
    end
  end
end
