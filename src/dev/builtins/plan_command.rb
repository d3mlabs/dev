# typed: strict
# frozen_string_literal: true

require "dev/command"
require "dev/workspace_root"
require "dev/plan"

module Dev
  module Builtins
    # `dev plan` is dispatched globally (before dev.yml lookup) in bin/dev;
    # this builtin only surfaces it in `dev --help` and keeps it callable
    # inside a project.
    class PlanCommand < BuiltinCommand
      extend T::Sig

      # Shared with the global usage listing (GlobalDispatch), which reads
      # descriptions without instantiating the builtin.
      DESC = "Sync Cursor plans with GitHub issues (new/link/pull/push/status/init)"

      # Builds the accessor anchored at the enclosing workspace (nearest dev.yml, else git root, else the cwd): a per-call value, since a global
      # command runs from any directory.
      AccessorFactory = T.type_alias { T.proc.returns(Dev::Plan::Accessor) }

      sig { params(accessor_factory: AccessorFactory).void }
      def initialize(accessor_factory: -> { Dev::Plan::Accessor.new(project_root: WorkspaceRoot.workspace) })
        super()
        @accessor_factory = accessor_factory
      end

      sig { override.returns(String) }
      def desc = DESC

      sig { override.returns(Command::Category) }
      def category = Command::Category::Workflow

      # plan never touches dependencies and runs headlessly from Cursor
      # hooks, where a staleness warning would only add noise.
      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        @accessor_factory.call.run(args)
      end
    end
  end
end
