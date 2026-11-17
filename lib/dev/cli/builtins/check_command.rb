# typed: strict
# frozen_string_literal: true

require "dev/cli/command"
require "dev/cli/dependency_service"
require "dev/deps/lockfile"

module Dev
  module Cli
    module Builtins
      # `dev deps check`: report the dependency-state freshness the staleness guard
      # would act on, and exit non-zero when anything drifted. Beside the
      # verdict, it names the pins no re-lock can keep — a steam branch tip
      # — so a lock that moves on every `dev deps update` is no surprise.
      class CheckCommand < BuiltinCommand
        extend T::Sig

        UNKEEPABLE_NOTE = "re-resolved on every dev deps update — the lock records what its service served, " \
          "with no source to hold it by"

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
          note_unkeepable(context)
          messages = @dependency_service.messages
          if messages.empty?
            puts "dev: dependency state is in sync (manifest, lockfiles, installed stamp)."
          else
            messages.each { |m| $stderr.puts "dev: #{m}" }
            Kernel.exit(1)
          end
        end

        private

        # Name each pin the lock cannot keep (Dependency#unkeepable?), one
        # line each. Outside a project there is no lock to read.
        #
        # @param context [ExecutionContext]
        # @return [void]
        sig { params(context: ExecutionContext).void }
        def note_unkeepable(context)
          project = context.project
          return if project.nil?

          Dev::Deps::Lockfile.new(dir: project.root).read.select(&:unkeepable?).each do |pin|
            puts "dev: #{pin.integration}/#{pin.name} #{pin.version}: #{UNKEEPABLE_NOTE}"
          end
        end
      end
    end
  end
end
