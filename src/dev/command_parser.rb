# typed: strict
# frozen_string_literal: true

require_relative "command"
require_relative "project_command_group"

module Dev
  # Parses a dev.yml command hash into its ProjectNode: a ProjectCommand
  # leaf, or — when the entry nests `commands:` — a ProjectCommandGroup
  # whose children parse recursively. An entry may declare `run`,
  # `commands`, or both (a runnable group); never neither.
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

    RESERVED_CHILD_NAME = "help"

    # Values may be nil for optional keys; `commands` nests further hashes.
    CommandHash = T.type_alias { T::Hash[String, T.untyped] }

    # @param name [String] the entry's name, as the user types it (nested
    #   entries carry their full path, e.g. "test unit") — for error messages
    # @param cmd_hash [CommandHash] the entry to parse
    # @return [ProjectNode] a leaf, or a group when `commands:` nests entries
    # @raise [MissingBodyError] when neither `run` nor `commands` is declared
    # @raise [ReplGroupError] when `repl: true` is declared on a group
    # @raise [ReservedChildNameError] when a child is named `help`
    # @raise [InvalidCommandsError] when `commands` is not a mapping
    sig { params(name: String, cmd_hash: CommandHash).returns(ProjectNode) }
    def parse(name, cmd_hash)
      run = cmd_hash["run"].to_s
      children = parse_children(name, cmd_hash["commands"])
      if run.empty? && children.empty?
        raise MissingBodyError, "command '#{name}' declares neither 'run' nor 'commands'"
      end

      # Coerces NilClass, TrueClass and FalseClass to String.
      desc = cmd_hash["desc"].to_s
      desc = desc.empty? ? "(no description)" : desc
      repl = cmd_hash["repl"] == true
      container = cmd_hash["container"] != false
      hidden = cmd_hash["hidden"] == true
      leaf = run.empty? ? nil : ProjectCommand.new(run:, desc:, repl:, container:, hidden:)

      return T.must(leaf) if children.empty?
      raise ReplGroupError, "command '#{name}' cannot be both a repl and a group of commands" if repl

      ProjectCommandGroup.new(children:, desc:, own: leaf, hidden:)
    end

    private

    # Parse the nested `commands:` mapping; absent or empty means a leaf.
    #
    # @param name [String] the parent's full name
    # @param raw [Object] the `commands` value as YAML delivered it
    # @return [Hash{String => ProjectNode}] in declaration order
    # @raise [InvalidCommandsError]
    # @raise [ReservedChildNameError]
    sig { params(name: String, raw: T.untyped).returns(T::Hash[String, ProjectNode]) }
    def parse_children(name, raw)
      return {} if raw.nil?
      raise InvalidCommandsError, "command '#{name}': 'commands' must be a mapping of name to command" unless raw.is_a?(Hash)

      raw.to_h do |child_name, child_hash|
        child_name = child_name.to_s
        if child_name == RESERVED_CHILD_NAME
          raise ReservedChildNameError, "command '#{name}': '#{RESERVED_CHILD_NAME}' is reserved and cannot name a subcommand"
        end

        # A non-mapping child body (nil, a bare string) has no keys to read
        # and surfaces as MissingBodyError under its own name.
        [child_name, parse("#{name} #{child_name}", child_hash.is_a?(Hash) ? child_hash : {})]
      end
    end
  end
end
