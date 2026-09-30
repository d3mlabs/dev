# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/command"
require "dev/credential_accessor"

module Dev
  module Builtins
    # `dev cred get <namespace> <key>`: print a stored credential, resolved
    # through the provider chain (ENV → keychain → file → prompt). The one
    # leaf of the host-global `cred` group (credentials live under XDG /
    # ~/.config/dev), so it needs no project.
    class CredGetCommand < BuiltinCommand
      extend T::Sig

      sig { params(accessor: Dev::CredentialAccessor, out: T.any(IO, StringIO)).void }
      def initialize(accessor: Dev::CredentialAccessor.new, out: $stdout)
        super()
        @accessor = accessor
        @out = out
      end

      sig { override.returns(String) }
      def desc = "Print a stored credential, resolved through the provider chain (get <namespace> <key>)"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Workflow

      # Host-global: a project's dependency staleness is irrelevant.
      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        @accessor.get(args, out: @out)
      end
    end
  end
end
