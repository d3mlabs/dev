# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/command"

module Dev
  module Builtins
    # `dev complete <words…>`: shell-completion plumbing. Given the words
    # typed after `dev` so far (not the one under the cursor), print the
    # names that can come next — the visible children of the node those
    # words reach — one per line; the shell does the prefix filtering. An
    # unknown word or a hidden node ends the walk with nothing to offer (so
    # does a leaf: it has no children to list). Hidden itself: the
    # completers installed by Cd::HookInstaller
    # call it, users never do.
    class CompleteCommand < BuiltinCommand
      extend T::Sig

      # The tree to walk, read at call time (the same self-reference help
      # resolves: the tree contains this command).
      RootProvider = T.type_alias { T.proc.returns(Command) }

      sig { params(root_provider: RootProvider, out: T.any(IO, StringIO)).void }
      def initialize(root_provider:, out: $stdout)
        super()
        @root_provider = root_provider
        @out = out
      end

      sig { override.returns(String) }
      def desc = "Print the command names that can follow the given words (shell completion plumbing)"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Workflow

      sig { override.returns(T::Boolean) }
      def hidden? = true

      # Completion must keep working while the dependency state is stale.
      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        candidates(args).each { |name| @out.puts name }
      end

      private

      # @param words [Array<String>] the words typed after `dev` so far
      # @return [Array<String>] the visible child names at the node reached
      sig { params(words: T::Array[String]).returns(T::Array[String]) }
      def candidates(words)
        node = T.let(@root_provider.call, Command)
        words.each do |word|
          child = node.children[word]
          return [] if child.nil? || child.hidden?

          node = child
        end
        node.children.reject { |_name, command| command.hidden? }.keys.sort
      end
    end
  end
end
