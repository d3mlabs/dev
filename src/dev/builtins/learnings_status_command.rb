# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/command"
require "dev/learnings"
require "dev/workspace_root"

module Dev
  module Builtins
    # `dev learnings status`: the configured knowledge repo, cache
    # location/age, and what is rendered and linked.
    # A leaf of the host-global `learnings` group: the accessor is anchored
    # at the enclosing project per call (nil outside any checkout, where
    # only the machine-global work happens).
    class LearningsStatusCommand < BuiltinCommand
      extend T::Sig

      AccessorFactory = T.type_alias { T.proc.returns(Dev::Learnings::Accessor) }

      USAGE = "usage: dev learnings status"

      sig { params(accessor_factory: AccessorFactory, out: T.any(IO, StringIO)).void }
      def initialize(
        accessor_factory: -> { Dev::Learnings::Accessor.new(project_root: WorkspaceRoot.enclosing_project) },
        out: $stdout
      )
        super()
        @accessor_factory = accessor_factory
        @out = out
      end

      sig { override.returns(String) }
      def desc = "Show the configured knowledge repo, cache location/age, what's rendered and linked"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Workflow

      # Host-global: a project's dependency staleness is irrelevant.
      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        raise Dev::Learnings::Accessor::UsageError, USAGE unless args.empty?

        @accessor_factory.call.status(out: @out)
      end
    end
  end
end
