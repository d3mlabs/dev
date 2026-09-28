# typed: strict
# frozen_string_literal: true

require_relative "command"
require_relative "command_executor"
require_relative "command_repository"
require_relative "dependency_service"
require_relative "execution_context"

module Dev
  # The command use case, and the only production consumer of the
  # CommandRepository (onion rule): resolve argv down the command tree,
  # guard dependency staleness, hand execution to the process boundary,
  # and record the installed stamp when the command stamps.
  class CommandService
    extend T::Sig

    sig do
      params(
        repository: CommandRepository,
        executor: CommandExecutor,
        dependency_service: DependencyService,
      ).void
    end
    def initialize(repository:, executor:, dependency_service:)
      @repository = repository
      @executor = executor
      @dependency_service = dependency_service
    end

    # Run one command end to end.
    #
    # The stamp is reached only when execute didn't raise, so it records a
    # fully-successful run — and only for wait-mode executions (the executor
    # runs stamping slots spawn-and-wait; an exec-replaced project command
    # never returns here, which is exactly why it must not stamp, #85).
    #
    # A runnable group invoked bare IS its own leaf: that leaf is what runs,
    # guards, and stamps. A pure group invoked bare reaches the executor as
    # itself (its group arm prints the usage).
    #
    # @param argv [Array<String>] the command path followed by its args
    # @param context [ExecutionContext]
    # @return [void]
    # @raise [CommandRepository::CommandNotFoundError] for an unknown path
    # @raise [DependencyService::StaleDependencyStateError] in CI, when the
    #   dependency state is stale
    # @raise [CommandRunner::CommandFailedError] when a waited child fails
    sig { params(argv: T::Array[String], context: ExecutionContext).void }
    def execute(argv, context:)
      resolution = @repository.resolve(argv)
      command = resolution.command
      command = command.own || command if command.is_a?(CommandGroup)
      @dependency_service.guard! unless command.staleness_exempt?
      @executor.execute(command, args: resolution.args, context:)
      @dependency_service.lock! if command.stamps?
    end

    # The commands usage advertises (the repository stays service-private).
    #
    # @return [Hash{String => Command}]
    sig { returns(T::Hash[String, Command]) }
    def visible_commands
      @repository.visible_commands
    end
  end
end
