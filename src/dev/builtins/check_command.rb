# typed: strict
# frozen_string_literal: true

require "dev/command"
require "dev/dependency_service"

module Dev
  module Builtins
    # `dev check`: report the dependency-state freshness the staleness guard
    # would act on, and exit non-zero when anything drifted.
    class CheckCommand < BuiltinCommand
      extend T::Sig

      sig { params(dependency_service: DependencyService).void }
      def initialize(dependency_service:)
        super()
        @dependency_service = T.let(dependency_service, DependencyService)
      end

      sig { override.returns(String) }
      def desc = "Check dependency state freshness (manifest vs lockfiles vs installed)"

      # check IS the explicit staleness inspection — guarding before it
      # would report the same thing twice.
      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        messages = @dependency_service.messages
        if messages.empty?
          puts "dev: dependency state is in sync (manifest, lockfiles, installed stamp)."
        else
          messages.each { |m| $stderr.puts "dev: #{m}" }
          Kernel.exit(1)
        end
      end
    end
  end
end
