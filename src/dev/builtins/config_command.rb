# typed: strict
# frozen_string_literal: true

require "dev/command"
require "dev/config_accessor"

module Dev
  module Builtins
    # `dev config` is dispatched globally (before dev.yml lookup) in bin/dev;
    # this builtin only surfaces it in `dev --help` and keeps it callable
    # inside a project.
    class ConfigCommand < BuiltinCommand
      extend T::Sig

      # Shared with the global usage listing (GlobalDispatch), which reads
      # descriptions without instantiating the builtin.
      DESC = "Manage dev settings (config list | get <key> | set <key> <value>)"

      sig { params(accessor: Dev::ConfigAccessor).void }
      def initialize(accessor: Dev::ConfigAccessor.new)
        super()
        @accessor = T.let(accessor, Dev::ConfigAccessor)
      end

      sig { override.returns(String) }
      def desc = DESC

      sig { override.returns(Command::Category) }
      def category = Command::Category::Workflow

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        @accessor.run(args)
      end
    end
  end
end
