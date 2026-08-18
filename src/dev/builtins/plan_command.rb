# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/builtin_body"
require "dev/plan"

module Dev
  module Builtins
    # `dev plan` is dispatched globally (before dev.yml lookup) in bin/dev;
    # this builtin only surfaces it in `dev --help` and keeps it callable
    # inside a project.
    class PlanCommand
      extend T::Sig
      include BuiltinBody

      # Builds the accessor for the enclosing project (per-call root).
      AccessorFactory = T.type_alias do
        T.proc.params(project_root: Pathname).returns(Dev::Plan::Accessor)
      end

      sig { params(accessor_factory: AccessorFactory).void }
      def initialize(accessor_factory: ->(project_root) { Dev::Plan::Accessor.new(project_root:) })
        @accessor_factory = T.let(accessor_factory, AccessorFactory)
      end

      sig { override.returns(String) }
      def desc = "Sync Cursor plans with GitHub issues (new/link/pull/push/status)"

      # plan never touches dependencies and runs headlessly from Cursor
      # hooks, where a staleness warning would only add noise.
      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        @accessor_factory.call(context.project_root).run(args)
      end
    end
  end
end
