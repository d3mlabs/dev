# typed: strict
# frozen_string_literal: true

require "dev/clone"
require "dev/command"

module Dev
  module Builtins
    # `dev clone` is dispatched globally (before dev.yml lookup) in bin/dev;
    # this builtin only surfaces it in `dev --help` and keeps it callable
    # inside a project.
    class CloneCommand < BuiltinCommand
      extend T::Sig

      sig { params(accessor: Dev::Clone::Accessor).void }
      def initialize(accessor: Dev::Clone::Accessor.new)
        super()
        @accessor = T.let(accessor, Dev::Clone::Accessor)
      end

      sig { override.returns(String) }
      def desc = "Clone a GitHub repo (via gh auth) into $DEV_CD_ROOT (default ~/src), org defaults to d3mlabs"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Workflow

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        @accessor.run(args)
      end
    end
  end
end
