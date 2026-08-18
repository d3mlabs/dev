# typed: strict
# frozen_string_literal: true

require "dev/builtin_body"
require "dev/cd"

module Dev
  module Builtins
    # `dev cd` is dispatched globally (before dev.yml lookup) in bin/dev;
    # this builtin only surfaces it in `dev --help` and keeps it callable
    # inside a project.
    class CdCommand
      extend T::Sig
      include BuiltinBody

      sig { params(accessor: Dev::Cd::Accessor).void }
      def initialize(accessor: Dev::Cd::Accessor.new)
        @accessor = T.let(accessor, Dev::Cd::Accessor)
      end

      sig { override.returns(String) }
      def desc = "Jump to a checkout under $DEV_CD_ROOT (default ~/src) by fuzzy name"

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        @accessor.run(args)
      end
    end
  end
end
