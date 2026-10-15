# typed: strict
# frozen_string_literal: true

require_relative "cli/flag_vocabulary"
require_relative "command"
require_relative "command_executor"
require_relative "command_repository"
require_relative "dependency_service"
require_relative "execution_context"

module Dev
  # The command use case, and the only production consumer of the
  # CommandRepository (onion rule): resolve argv down the command tree,
  # admit the args against the node's flag vocabulary, guard dependency
  # staleness, hand execution to the process boundary, and record the
  # installed stamp when the command stamps.
  class CommandService
    extend T::Sig

    sig do
      params(
        repository: CommandRepository,
        executor: CommandExecutor,
        dependency_service: DependencyService,
        flag_vocabulary: Cli::FlagVocabulary,
      ).void
    end
    def initialize(repository:, executor:, dependency_service:, flag_vocabulary: Cli::FlagVocabulary.new)
      @repository = repository
      @executor = executor
      @dependency_service = dependency_service
      @flag_vocabulary = flag_vocabulary
    end

    # Run one command end to end.
    #
    # Admission comes first: a usage error is answered before the staleness
    # guard gets to nag. The stamp is reached only when execute didn't
    # raise, so it records a fully-successful run — and only for wait-mode
    # executions (the executor runs stamping slots spawn-and-wait; an
    # exec-replaced project command never returns here, which is exactly
    # why it must not stamp, #85).
    #
    # @param argv [Array<String>] the command path followed by its args
    # @param context [ExecutionContext]
    # @return [void]
    # @raise [CommandRepository::CommandNotFoundError] for an unknown path
    # @raise [Cli::FlagVocabulary::UnknownFlagError] for a flag the node
    #   does not declare
    # @raise [DependencyService::StaleDependencyStateError] in CI, when the
    #   dependency state is stale
    # @raise [CommandRunner::CommandFailedError] when a waited child fails
    sig { params(argv: T::Array[String], context: ExecutionContext).void }
    def execute(argv, context:)
      resolution = @repository.resolve(argv)
      command = resolution.command
      args = @flag_vocabulary.admit(command, path: resolution.path, args: resolution.args)
      @dependency_service.guard! unless command.staleness_exempt?
      @executor.execute(command, args:, context:)
      @dependency_service.lock! if command.stamps?
    end

    # Where argv lands in the tree, without running anything — what a router
    # needs to rewrite a node's `--help` into `help <path>` (the repository
    # stays service-private).
    #
    # @param argv [Array<String>] the command path followed by its args
    # @return [CommandRepository::Resolution]
    # @raise [CommandRepository::CommandNotFoundError] for an unknown path
    sig { params(argv: T::Array[String]).returns(CommandRepository::Resolution) }
    def resolve(argv)
      @repository.resolve(argv)
    end

    # The tree help and completion walk (the repository stays
    # service-private).
    #
    # @return [CommandGroup] the root node
    sig { returns(CommandGroup) }
    def root
      @repository.root
    end
  end
end
