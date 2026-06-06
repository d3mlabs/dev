# typed: strict
# frozen_string_literal: true

require_relative "command"
require_relative "builtin_command"
require_relative "overridden_command"

module Dev
  # Command registry with OOP override semantics.
  #
  # - BuiltinCommand registers as a virtual slot (overridable)
  # - ShellCommand registers as a final slot (non-overridable)
  # - ShellCommand into a virtual slot creates an OverriddenCommand
  #   (built-in runs first, like a hardcoded super())
  # - Any registration into a final slot raises DuplicateCommandError
  # - BuiltinCommand into an occupied slot raises DuplicateCommandError
  class CommandRegistry
    extend T::Sig

    class DuplicateCommandError < StandardError; end
    class CommandNotFoundError < StandardError; end

    sig { void }
    def initialize
      @commands = T.let({}, T::Hash[String, Command])
      @virtual = T.let(Set.new, T::Set[String])
    end

    # Register a command. Override semantics derived from type:
    #
    # @param name [String] command name
    # @param command [Command] command to register
    # @raise [DuplicateCommandError] if registering into a final slot,
    #   or a BuiltinCommand into an occupied slot
    sig { params(name: String, command: Command).void }
    def register(name, command)
      existing = @commands[name]

      if existing.nil?
        @commands[name] = command
        @virtual.add(name) if command.is_a?(BuiltinCommand)
      elsif @virtual.include?(name) && !command.is_a?(BuiltinCommand)
        @commands[name] = OverriddenCommand.new(super_command: existing, body: command)
        @virtual.delete(name)
      else
        raise DuplicateCommandError, "Command '#{name}' is already registered and cannot be overridden"
      end
    end

    # Look up a command by name.
    #
    # @param name [String] command name
    # @return [Command]
    # @raise [CommandNotFoundError] if no command is registered with that name
    sig { params(name: String).returns(Command) }
    def lookup(name)
      @commands.fetch(name) do
        raise CommandNotFoundError, "Command '#{name}' not found"
      end
    end

    # All registered commands (resolved leaf view).
    #
    # @return [Hash{String => Command}]
    sig { returns(T::Hash[String, Command]) }
    def all
      @commands.dup
    end

  end
end
