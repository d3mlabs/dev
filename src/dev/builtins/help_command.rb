# typed: strict
# frozen_string_literal: true

require "stringio"

require "dev/cli/usage_printer"
require "dev/command"

module Dev
  module Builtins
    # `dev help` (also routed from bare `dev`, `--help`, and `-h`): render
    # the grouped usage listing. Help lists the very catalog that contains
    # it, so the listing arrives as a provider resolved at call time — the
    # composition root closes the self-reference, not this class.
    class HelpCommand < BuiltinCommand
      extend T::Sig

      CommandsProvider = T.type_alias { T.proc.returns(T::Hash[String, Command]) }

      sig do
        params(
          project_name: String,
          usage_printer: Cli::UsagePrinter,
          out: T.any(IO, StringIO),
          commands_provider: CommandsProvider,
        ).void
      end
      def initialize(project_name:, usage_printer:, out:, commands_provider:)
        super()
        @project_name = T.let(project_name, String)
        @usage_printer = T.let(usage_printer, Cli::UsagePrinter)
        @out = T.let(out, T.any(IO, StringIO))
        @commands_provider = T.let(commands_provider, CommandsProvider)
      end

      sig { override.returns(String) }
      def desc = "Show this usage"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Workflow

      # Help must work while the dependency state is stale — it is how the
      # remediation commands get discovered in the first place.
      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        @usage_printer.print(project_name: @project_name, commands: @commands_provider.call, out: @out)
      end
    end
  end
end
