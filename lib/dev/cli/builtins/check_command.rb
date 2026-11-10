# typed: strict
# frozen_string_literal: true

require "dev/cli/command"
require "dev/cli/dependency_service"

module Dev
  module Cli
    module Builtins
      # `dev deps check`: report the dependency-state freshness the staleness guard
      # would act on, and exit non-zero when anything drifted.
      class CheckCommand < BuiltinCommand
        extend T::Sig

        sig { params(dependency_service: DependencyService).void }
        def initialize(dependency_service:)
          super()
          @dependency_service = dependency_service
        end

        sig { override.returns(String) }
        def desc
          "Check dependency state freshness (manifest vs lockfiles vs installed)"
        end

        sig { override.returns(Command::Category) }
        def category
          Command::Category::Environment
        end

        # check IS the explicit staleness inspection — guarding before it
        # would report the same thing twice.
        sig { override.returns(T::Boolean) }
        def staleness_exempt?
          true
        end

        sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
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
end
