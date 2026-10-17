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

      # Shared with the global usage listing (GlobalDispatch), which reads
      # descriptions without instantiating the builtin.
      DESC = "Clone a GitHub repo (via gh auth) into $DEV_CD_ROOT (default ~/src); " \
        "bare names expand under the default_org setting"

      # The shell wrapper's plumbing mode (hidden from users): print the
      # destination path so the wrapper can land in it.
      PATH_FLAG = "--path"

      sig { params(accessor: Dev::Clone::Accessor).void }
      def initialize(accessor: Dev::Clone::Accessor.new)
        super()
        @accessor = accessor
      end

      sig { override.returns(String) }
      def desc = DESC

      sig { override.returns(Command::Category) }
      def category = Command::Category::Workflow

      sig { override.returns(T::Array[Cli::Flag]) }
      def flags = [Cli::Flag.new(PATH_FLAG)]

      sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
      def call(args:, context:)
        raise Dev::Clone::Accessor::UsageError, "usage: dev clone [<org>/]<repo>" unless args.positionals.size == 1

        @accessor.run(args.positionals.fetch(0), plumbing: args.flag?(PATH_FLAG), out: $stdout, err: $stderr)
      end
    end
  end
end
