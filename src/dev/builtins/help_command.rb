# typed: strict
# frozen_string_literal: true

require "stringio"

require "dev/cli/usage_printer"
require "dev/command"

module Dev
  module Builtins
    # `dev help <path…>`: render the usage of the node at that path — its
    # invocation forms, description, children; with no path, the root
    # (the same view bare `dev`, `--help`, and `-h` reach by resolving to
    # the root). Help walks the very tree that contains it, so the root
    # arrives as a provider resolved at call time — the composition root
    # closes the self-reference, not this class.
    class HelpCommand < BuiltinCommand
      extend T::Sig

      # `dev help <path…>` named something the tree does not hold.
      class UnknownCommandError < ArgumentError; end

      RootProvider = T.type_alias { T.proc.returns(Command) }

      sig do
        params(
          usage_printer: Cli::UsagePrinter,
          out: T.any(IO, StringIO),
          root_provider: RootProvider,
        ).void
      end
      def initialize(usage_printer:, out:, root_provider:)
        super()
        @usage_printer = usage_printer
        @out = out
        @root_provider = root_provider
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
        @usage_printer.print_node(path: args, command: walk(@root_provider.call, args), out: @out)
      end

      private

      # Follow the path down from the root, one child per token.
      #
      # @param root [Command]
      # @param path [Array<String>]
      # @return [Command] the node at the path (the root for an empty path)
      # @raise [UnknownCommandError]
      sig { params(root: Command, path: T::Array[String]).returns(Command) }
      def walk(root, path)
        path.reduce(root) do |node, name|
          # A leaf has no children: any further token falls through to the raise.
          node.children[name] || raise(UnknownCommandError, "help: unknown command '#{path.join(" ")}'")
        end
      end
    end
  end
end
