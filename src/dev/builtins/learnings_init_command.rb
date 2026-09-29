# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/command"
require "dev/learnings"
require "dev/workspace_root"

module Dev
  module Builtins
    # `dev learnings init [--org]`: scaffold this repo's empty learnings index,
    # or with --org the org knowledge-repo layout (index.md + skills/).
    # Write-once: an existing index is left untouched.
    # A leaf of the host-global `learnings` group: the accessor is anchored
    # at the enclosing project per call (nil outside any checkout, where
    # only the machine-global work happens).
    class LearningsInitCommand < BuiltinCommand
      extend T::Sig

      AccessorFactory = T.type_alias { T.proc.returns(Dev::Learnings::Accessor) }

      USAGE = "usage: dev learnings init [--org]"

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
      def desc = "Scaffold this repo's learnings index, or the org knowledge-repo layout (--org); write-once"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Workflow

      # Host-global: a project's dependency staleness is irrelevant.
      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        flags = args.dup
        org = flags.delete("--org") ? true : false
        raise Dev::Learnings::Accessor::UsageError, USAGE unless flags.empty?

        @accessor_factory.call.init(out: @out, org: org)
      end
    end
  end
end
