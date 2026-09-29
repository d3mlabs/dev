# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/command"
require "dev/plan"
require "dev/workspace_root"

module Dev
  module Builtins
    # The shape every `dev plan <verb>` leaf shares: the accessor is built
    # per call, anchored at the enclosing workspace (nearest dev.yml, else
    # git root, else the cwd — a global command runs from any directory),
    # the host hook point runs first (shipped skill links + org learnings
    # artifacts, see Plan::Accessor#refresh_host), then the verb. Subclasses
    # own the verb: its argv shape and which accessor method it calls.
    class PlanVerbCommand < BuiltinCommand
      extend T::Sig
      extend T::Helpers

      abstract!

      AccessorFactory = T.type_alias { T.proc.returns(Dev::Plan::Accessor) }

      sig { params(accessor_factory: AccessorFactory, out: T.any(IO, StringIO)).void }
      def initialize(
        accessor_factory: -> { Dev::Plan::Accessor.new(project_root: WorkspaceRoot.workspace) },
        out: $stdout
      )
        super()
        @accessor_factory = accessor_factory
        @out = out
      end

      sig { override.returns(Command::Category) }
      def category = Command::Category::Workflow

      # plan never touches dependencies and runs headlessly from Cursor
      # hooks, where a staleness warning would only add noise.
      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        accessor = @accessor_factory.call
        accessor.refresh_host
        perform(accessor, args)
      end

      private

      # The verb itself, after the host refresh.
      #
      # @param accessor [Dev::Plan::Accessor] anchored at the workspace
      # @param args [Array<String>] argv after the verb
      # @return [void]
      sig { abstract.params(accessor: Dev::Plan::Accessor, args: T::Array[String]).void }
      def perform(accessor, args); end
    end
  end
end
