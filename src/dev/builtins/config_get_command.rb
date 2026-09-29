# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/command"
require "dev/config_accessor"

module Dev
  module Builtins
    # `dev config get <key>`: print one setting's resolved value. A leaf of the host-global
    # `config` group (settings live under XDG / ~/.config/dev), so it needs
    # no project.
    class ConfigGetCommand < BuiltinCommand
      extend T::Sig

      sig { params(accessor: Dev::ConfigAccessor, out: T.any(IO, StringIO)).void }
      def initialize(accessor: Dev::ConfigAccessor.new, out: $stdout)
        super()
        @accessor = accessor
        @out = out
      end

      sig { override.returns(String) }
      def desc = "Print a setting's resolved value (get <key>)"

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
