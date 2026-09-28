# typed: strict
# frozen_string_literal: true

require "stringio"

require "dev/cli/usage_printer"
require "dev/command"

module Dev
  module Builtins
    # `dev help` (also routed from bare `dev`, `--help`, and `-h`): render
    # the grouped usage listing; `dev help <path…>` renders the usage of
    # the node at that path (a group's children, or a leaf's one line).
    # Help lists the very catalog that contains it, so the listing arrives
    # as a provider resolved at call time — the composition root closes the
    # self-reference, not this class.
    class HelpCommand < BuiltinCommand
      extend T::Sig

      # `dev help <path…>` named something the tree does not hold.
      class UnknownCommandError < ArgumentError; end

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
        @project_name = project_name
        @usage_printer = usage_printer
        @out = out
        @commands_provider = commands_provider
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
        commands = @commands_provider.call
        return @usage_printer.print(project_name: @project_name, commands: commands, out: @out) if args.empty?

        command = walk(commands, args)
        if command.is_a?(CommandGroup)
          @usage_printer.print_group(group: command, out: @out)
        else
          @out.puts "Usage: dev #{args.join(" ")} [args...]"
          @out.puts ""
          @out.puts command.desc
        end
      end

      private

      # Follow the path through the listing, one child per token.
      #
      # @param commands [Hash{String => Command}] the top-level listing
      # @param path [Array<String>]
      # @return [Command] the node at the path
      # @raise [UnknownCommandError]
      sig { params(commands: T::Hash[String, Command], path: T::Array[String]).returns(Command) }
      def walk(commands, path)
        children = commands
        node = T.let(nil, T.nilable(Command))
        path.each do |name|
          node = children[name]
          raise UnknownCommandError, "help: unknown command '#{path.join(" ")}'" if node.nil?

          # A leaf has no children: any further token falls through to the raise.
          children = node.is_a?(CommandGroup) ? node.children : {}
        end
        T.must(node)
      end
    end
  end
end
