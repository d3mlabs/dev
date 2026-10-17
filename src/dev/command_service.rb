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
  # answer a help request with the node's usage, parse the args against the
  # node's flag vocabulary, guard dependency staleness, hand execution to
  # the process boundary, and record the installed stamp when the command
  # stamps.
  class CommandService
    extend T::Sig

    # The tree's usage node: a help request at any node runs it with that
    # node's path, so `dev container up --help` and `dev help container up`
    # are one rendering.
    HELP_COMMAND = "help"

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
    # A help request is answered before anything else: `-h`/`--help` among
    # a dev-defined node's args (before any `--`) runs the help node with
    # that node's path instead. Parsing comes next, so a usage error is
    # answered before the staleness guard gets to nag. The stamp is reached
    # only when execute didn't raise, so it records a fully-successful run
    # — and only for wait-mode executions (the executor runs stamping slots
    # spawn-and-wait; an exec-replaced project command never returns here,
    # which is exactly why it must not stamp, #85).
    #
    # @param argv [Array<String>] the command path followed by its args
    # @param context [ExecutionContext]
    # @return [void]
    # @raise [CommandRepository::CommandNotFoundError] for an unknown path
    # @raise [Cli::FlagVocabulary::UsageError] for a flag the node does not
    #   declare, or one used against its arity
    # @raise [DependencyService::StaleDependencyStateError] in CI, when the
    #   dependency state is stale
    # @raise [CommandRunner::CommandFailedError] when a waited child fails
    sig { params(argv: T::Array[String], context: ExecutionContext).void }
    def execute(argv, context:)
      resolution = @repository.resolve(argv)
      resolution = @repository.resolve([HELP_COMMAND, *resolution.path]) if help_requested?(resolution)
      command = resolution.command
      args = @flag_vocabulary.parse(command, path: resolution.path, args: resolution.args)
      @dependency_service.guard! unless command.staleness_exempt?
      @executor.execute(command, args:, context:)
      @dependency_service.lock! if command.stamps?
    end

    # The tree help and completion walk (the repository stays
    # service-private).
    #
    # @return [CommandGroup] the root node
    sig { returns(CommandGroup) }
    def root
      @repository.root
    end

    private

    # Whether the resolved node's args ask for its usage. An opaque node's
    # argv is someone else's (Command#opaque_args?), so a help flag there is
    # data, not a request.
    #
    # @param resolution [CommandRepository::Resolution]
    # @return [Boolean]
    sig { params(resolution: CommandRepository::Resolution).returns(T::Boolean) }
    def help_requested?(resolution)
      !resolution.command.opaque_args? && @flag_vocabulary.help_requested?(resolution.args)
    end
  end
end
