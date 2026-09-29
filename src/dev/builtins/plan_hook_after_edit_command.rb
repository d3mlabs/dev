# typed: strict
# frozen_string_literal: true

require "dev/builtins/plan_verb_command"

module Dev
  module Builtins
    # `dev plan hook-after-edit`: the Cursor `afterFileEdit` hook
    # (registered by a participating repo's .cursor/hooks.json): reads the
    # hook payload from stdin and auto-pushes the edited file when it is a
    # linked plan, else no-ops. Plumbing, so hidden from the listings.
    class PlanHookAfterEditCommand < PlanVerbCommand
      extend T::Sig

      sig do
        params(
          accessor_factory: AccessorFactory,
          out: T.any(IO, StringIO),
          input: T.any(IO, StringIO),
        ).void
      end
      def initialize(
        accessor_factory: -> { Dev::Plan::Accessor.new(project_root: WorkspaceRoot.workspace) },
        out: $stdout,
        input: $stdin
      )
        super(accessor_factory:, out:)
        @input = input
      end

      sig { override.returns(String) }
      def desc = "Cursor afterFileEdit hook: auto-push an edited linked plan (payload on stdin)"

      sig { override.returns(T::Boolean) }
      def hidden? = true

      private

      sig { override.params(accessor: Dev::Plan::Accessor, args: T::Array[String]).void }
      def perform(accessor, args)
        raise Dev::Plan::Accessor::UsageError, "usage: dev plan hook-after-edit" unless args.empty?

        accessor.hook_after_edit(@input, out: @out)
      end
    end
  end
end
