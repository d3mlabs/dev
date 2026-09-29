# typed: strict
# frozen_string_literal: true

require "dev/command"
require "dev/workspace_root"
require "dev/learnings"

module Dev
  module Builtins
    # `dev learnings` is dispatched globally (before dev.yml lookup) in
    # bin/dev; this builtin only surfaces it in `dev --help` and keeps it
    # callable inside a project.
    class LearningsCommand < BuiltinCommand
      extend T::Sig

      # Shared with the global usage listing (GlobalDispatch), which reads
      # descriptions without instantiating the builtin.
      DESC = "Learnings read path (sync: refresh now, status: what's linked, invariants: Tier-0 block, " \
        "init: scaffold the index)"

      # Builds the accessor anchored at the enclosing project (nearest dev.yml, else git root; nil outside any checkout): a per-call value, since a global
      # command runs from any directory.
      AccessorFactory = T.type_alias { T.proc.returns(Dev::Learnings::Accessor) }

      sig { params(accessor_factory: AccessorFactory).void }
      def initialize(accessor_factory: -> { Dev::Learnings::Accessor.new(project_root: WorkspaceRoot.enclosing_project) })
        super()
        @accessor_factory = accessor_factory
      end

      sig { override.returns(String) }
      def desc = DESC

      sig { override.returns(Command::Category) }
      def category = Command::Category::Workflow

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        @accessor_factory.call.run(args)
      end
    end
  end
end
