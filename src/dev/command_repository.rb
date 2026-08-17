# typed: strict
# frozen_string_literal: true

require_relative "command"

module Dev
  # Assembles the sealed Command domain objects a project exposes: the
  # builtin set the composition root gated into existence, the project
  # commands parsed from dev.yml, and — where a project command occupies a
  # builtin's slot — their OverriddenCommand composition. Data in, never a
  # path, never a parse.
  #
  # Onion rule: CommandService is the only production consumer; the constant
  # is private and construction is confined to the composition root.
  class CommandRepository
    extend T::Sig

    class CommandNotFoundError < StandardError; end

    # @param builtins [Hash{String => BuiltinCommand}] the builtins that
    #   exist for this project, in listing order
    # @param project_commands [Hash{String => ProjectCommand}] parsed dev.yml
    #   commands, in declaration order
    sig do
      params(
        builtins: T::Hash[String, BuiltinCommand],
        project_commands: T::Hash[String, ProjectCommand],
      ).void
    end
    def initialize(builtins:, project_commands:)
      @commands = T.let(assemble(builtins, project_commands).freeze, T::Hash[String, Command])
    end

    # Look up a command by name.
    #
    # @param name [String] command name
    # @return [Command]
    # @raise [CommandNotFoundError] if no command exists with that name
    sig { params(name: String).returns(Command) }
    def fetch(name)
      @commands.fetch(name) do
        raise CommandNotFoundError, "Command '#{name}' not found"
      end
    end

    # The commands usage advertises, in listing order (hidden ones stay
    # callable but unlisted).
    #
    # @return [Hash{String => Command}]
    sig { returns(T::Hash[String, Command]) }
    def visible_commands
      @commands.reject { |_name, command| command.hidden? }
    end

    private

    # Merge builtins and project commands into the resolved leaf view. A
    # project command on a builtin's name composes into an OverriddenCommand
    # in the builtin's listing position; hash keys are unique, so a
    # duplicate project declaration is unrepresentable.
    #
    # @param builtins [Hash{String => BuiltinCommand}]
    # @param project_commands [Hash{String => ProjectCommand}]
    # @return [Hash{String => Command}]
    sig do
      params(
        builtins: T::Hash[String, BuiltinCommand],
        project_commands: T::Hash[String, ProjectCommand],
      ).returns(T::Hash[String, Command])
    end
    def assemble(builtins, project_commands)
      commands = T.let(builtins.dup, T::Hash[String, Command])
      project_commands.each do |name, project_command|
        builtin = builtins[name]
        commands[name] = builtin ? OverriddenCommand.new(builtin:, project: project_command) : project_command
      end
      commands
    end
  end

  private_constant :CommandRepository
end
