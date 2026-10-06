# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/command"

module Dev
  module Builtins
    # `dev complete <words…>`: shell-completion plumbing. Given the words
    # typed after `dev` so far (not the one under the cursor), print the
    # names that can come next — the visible children of the node those
    # words reach, sorted — one per line; the shell does the prefix
    # filtering. An unknown word under a node with children, or a hidden
    # node, ends the walk with nothing to offer. When the walk ends on a
    # leaf, the leaf's own `completions` (over the words after its name)
    # are printed instead, in the leaf's order — this command never sorts
    # them (#211: order is the leaf's to decide). Hidden itself: the
    # completers installed by Cd::HookInstaller call it, users never do.
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
      #   (sorted), or — at a leaf — its own argument completions (as given)
      sig { params(words: T::Array[String]).returns(T::Array[String]) }
      def candidates(words)
        node = T.let(@root_provider.call, Command)
        remaining = words.dup
        while (word = remaining.first)
          child = node.children[word]
          break if child.nil?
          return [] if child.hidden?

          node = child
          remaining.shift
        end

        visible = node.children.reject { |_name, command| command.hidden? }
        return node.completions(remaining) if visible.empty?
        return [] unless remaining.empty?

        visible.keys.sort
      end
    end
  end
end
