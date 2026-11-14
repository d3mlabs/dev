# typed: strict
# frozen_string_literal: true

require "dev/environment_ref"
require_relative "command"

module Dev
  module Cli
    # Parses a dev.yml command hash into its ProjectNode: a ProjectCommand
    # (with the nested `commands:`, parsed recursively, as its children) or —
    # when the entry has `commands:` but no `run:` — a CommandGroup. An entry
    # may declare `run`, `commands`, or both; never neither.
    class CommandParser
      extend T::Sig

      # The entry declares neither `run` nor `commands`: nothing to do when
      # invoked, nothing to descend into.
      class MissingBodyError < ArgumentError; end

      # `repl: true` beside `commands:` — a REPL owns the terminal and cannot
      # also be the dispatcher of subcommands.
      class ReplGroupError < ArgumentError; end

      # A child named `help`: the tree reserves the word so `dev <group>
      # help`-style introspection never collides with a project leaf.
      class ReservedChildNameError < ArgumentError; end

      # `commands:` holding something other than a mapping of name → entry.
      class InvalidCommandsError < ArgumentError; end

      # `environment:` holding something other than a name (an image's, or
      # `host`).
      class InvalidEnvironmentError < ArgumentError; end

      RESERVED_CHILD_NAME = "help"
      # The key naming the environment a command's body executes in.
      ENVIRONMENT_KEY = "environment"

      # Values may be nil for optional keys; `commands` nests further hashes.
      CommandHash = T.type_alias { T::Hash[String, T.untyped] }

      # @param path [Array<String>] the entry's command path from the root
      #   (`["test"]`, `["test", "unit"]`) — what errors and group usage name
      # @param cmd_hash [CommandHash] the entry to parse
      # @return [ProjectNode]
      # @raise [MissingBodyError] when neither `run` nor `commands` is declared
      # @raise [ReplGroupError] when `repl: true` is declared beside `commands`
      # @raise [ReservedChildNameError] when a child is named `help`
      # @raise [InvalidCommandsError] when `commands` is not a mapping
      # @raise [InvalidEnvironmentError] when `environment` is not a name
      sig { params(path: T::Array[String], cmd_hash: CommandHash).returns(ProjectNode) }
      def parse(path, cmd_hash)
        name = path.join(" ")
        run = cmd_hash["run"].to_s
        children = parse_children(path, cmd_hash["commands"])
        if run.empty? && children.empty?
          raise MissingBodyError, "command '#{name}' declares neither 'run' nor 'commands'"
        end

        # Coerces NilClass, TrueClass and FalseClass to String.
        desc = cmd_hash["desc"].to_s
        desc = desc.empty? ? "(no description)" : desc
        repl = cmd_hash["repl"] == true
        environment = parse_environment(name, cmd_hash)
        hidden = cmd_hash["hidden"] == true
        if repl && !children.empty?
          raise ReplGroupError, "command '#{name}' cannot be both a repl and a group of commands"
        end
        return CommandGroup.new(path:, desc:, category: Command::Category::Project, children:, hidden:) if run.empty?

        ProjectCommand.new(run:, desc:, repl:, environment:, hidden:, children:)
      end

      private

      # The `environment:` value as a reference — unresolved: the lock is
      # the composition root's to consult (ProjectImages#bind), so the
      # parser stays lock-free. A non-empty string, declared alone.
      #
      # @param name [String] the command's path, for messages
      # @param cmd_hash [CommandHash]
      # @return [EnvironmentRef, nil] nil when absent
      # @raise [InvalidEnvironmentError]
      sig { params(name: String, cmd_hash: CommandHash).returns(T.nilable(EnvironmentRef)) }
      def parse_environment(name, cmd_hash)
        return nil unless cmd_hash.key?(ENVIRONMENT_KEY)

        raw = cmd_hash[ENVIRONMENT_KEY]
        unless raw.is_a?(String) && !raw.empty?
          raise InvalidEnvironmentError,
            "command '#{name}': '#{ENVIRONMENT_KEY}' must name an image block or be '#{EnvironmentRef::HOST}', got #{raw.inspect}"
        end
        EnvironmentRef.parse(raw)
      end

      # Parse the nested `commands:` mapping; absent or empty means none.
      #
      # @param path [Array<String>] the parent's path
      # @param raw [Object] the `commands` value as YAML delivered it
      # @return [Hash{String => Command}] in declaration order
      # @raise [InvalidCommandsError]
      # @raise [ReservedChildNameError]
      sig { params(path: T::Array[String], raw: T.untyped).returns(T::Hash[String, Command]) }
      def parse_children(path, raw)
        return {} if raw.nil?

        name = path.join(" ")
        raise InvalidCommandsError, "command '#{name}': 'commands' must be a mapping of name to command" unless raw.is_a?(Hash)

        raw.to_h do |child_name, child_hash|
          child_name = child_name.to_s
          if child_name == RESERVED_CHILD_NAME
            raise ReservedChildNameError, "command '#{name}': '#{RESERVED_CHILD_NAME}' is reserved and cannot name a subcommand"
          end

          # A non-mapping child body (nil, a bare string) has no keys to read
          # and surfaces as MissingBodyError under its own name.
          [child_name, T.let(parse(path + [child_name], child_hash.is_a?(Hash) ? child_hash : {}), Command)]
        end
      end
    end
  end
end
