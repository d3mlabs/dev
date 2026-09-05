# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/command"
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

      # Builds the accessor for the enclosing project (per-call root).
      AccessorFactory = T.type_alias do
        T.proc.params(project_root: Pathname).returns(Dev::Learnings::Accessor)
      end

      sig { params(accessor_factory: AccessorFactory).void }
      def initialize(accessor_factory: ->(project_root) { Dev::Learnings::Accessor.new(project_root:) })
        super()
        @accessor_factory = accessor_factory
      end

      sig { override.returns(String) }
      def desc = DESC

      sig { override.returns(Command::Category) }
      def category = Command::Category::Workflow

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        @accessor_factory.call(context.project_root).run(args)
      end
    end
  end
end
