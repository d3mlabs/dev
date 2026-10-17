# typed: strict
# frozen_string_literal: true

require "dev/cd"
require "dev/command"

module Dev
  module Builtins
    # `dev cd` is dispatched globally (before dev.yml lookup) in bin/dev;
    # this builtin only surfaces it in `dev --help` and keeps it callable
    # inside a project.
    class CdCommand < BuiltinCommand
      extend T::Sig

      # Shared with the global usage listing (GlobalDispatch), which reads
      # descriptions without instantiating the builtin.
      DESC = "Jump to a checkout under $DEV_CD_ROOT (default ~/src) by fuzzy name"

      # The shell wrapper's plumbing modes (hidden from users): print the one
      # resolved path, or the ranked candidates for completion.
      RESOLVE_FLAG = "--resolve"
      CANDIDATES_FLAG = "--candidates"

      sig { params(accessor: Dev::Cd::Accessor).void }
      def initialize(accessor: Dev::Cd::Accessor.new)
        super()
        @accessor = accessor
      end

      sig { override.returns(String) }
      def desc = DESC

      sig { override.returns(Command::Category) }
      def category = Command::Category::Workflow

      sig { override.returns(T::Array[Cli::Flag]) }
      def flags = [Cli::Flag.new(RESOLVE_FLAG), Cli::Flag.new(CANDIDATES_FLAG)]

      # A bare `dev cd` reaching this process means the shell wrapper is not
      # active: a child process cannot change its parent's cwd.
      sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
      def call(args:, context:)
        query = args.positionals
        if args.flag?(RESOLVE_FLAG)
          raise Dev::Cd::Accessor::UsageError, "usage: dev cd <query>" unless query.size == 1

          @accessor.resolve(query.fetch(0), out: $stdout, err: $stderr)
        elsif args.flag?(CANDIDATES_FLAG)
          raise Dev::Cd::Accessor::UsageError, "usage: dev cd #{CANDIDATES_FLAG} [<query>]" if query.size > 1

          @accessor.candidates(query.fetch(0, ""), out: $stdout)
        else
          @accessor.explain_missing_hook(err: $stderr)
        end
      end
    end
  end
end
