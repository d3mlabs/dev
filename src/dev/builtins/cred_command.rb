# typed: strict
# frozen_string_literal: true

require "dev/command"
require "dev/credential_accessor"

module Dev
  module Builtins
    # `dev cred` is dispatched globally (before dev.yml lookup) in bin/dev;
    # this builtin only surfaces it in `dev --help` and keeps it callable
    # inside a project.
    class CredCommand < BuiltinCommand
      extend T::Sig

      sig { params(accessor: Dev::CredentialAccessor).void }
      def initialize(accessor: Dev::CredentialAccessor.new)
        super()
        @accessor = T.let(accessor, Dev::CredentialAccessor)
      end

      sig { override.returns(String) }
      def desc = "Resolve a stored credential (e.g. cred get <namespace> <key>)"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Workflow

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        @accessor.run(args)
      end
    end
  end
end
