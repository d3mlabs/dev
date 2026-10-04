# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/command"
require "dev/version"

module Dev
  module Builtins
    # `dev version` (also `dev --version`) — print this dev's version, one
    # line, nothing else. Global: it answers for the binary, not a project.
    # Machine-readable by design: the host runs it inside a container to
    # decide whether the container's dev needs provisioning at the host's
    # version (ContainerDevProvisioner).
    class VersionCommand < BuiltinCommand
      extend T::Sig

      # @param out [IO, StringIO]
      sig { params(out: T.any(IO, StringIO)).void }
      def initialize(out: $stdout)
        super()
        @out = out
      end

      sig { override.returns(String) }
      def desc = "Print this dev's version"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Workflow

      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      # @param args [Array<String>] unused
      # @param context [ExecutionContext] unused: the version is the binary's
      # @return [void]
      # @raise [Dev::Version::UnknownVersionError] when this install ships no VERSION file
      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        @out.puts Dev::Version.current
      end
    end
  end
end
