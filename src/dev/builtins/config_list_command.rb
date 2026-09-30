# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/command"
require "dev/config_accessor"

module Dev
  module Builtins
    # `dev config list`: every known setting with its resolved value and source layer. A leaf of the host-global
    # `config` group (settings live under XDG / ~/.config/dev), so it needs
    # no project.
    class ConfigListCommand < BuiltinCommand
      extend T::Sig

      sig { params(accessor: Dev::ConfigAccessor, out: T.any(IO, StringIO)).void }
      def initialize(accessor: Dev::ConfigAccessor.new, out: $stdout)
        super()
        @accessor = accessor
        @out = out
      end

      sig { override.returns(String) }
      def desc = "List every setting with its resolved value and source layer"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Workflow

      # Host-global: a project's dependency staleness is irrelevant.
      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        raise Dev::ConfigAccessor::UsageError, Dev::ConfigAccessor::USAGE unless args.empty?

        @accessor.list(out: @out)
      end
    end
  end
end
