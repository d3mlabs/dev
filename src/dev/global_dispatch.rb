# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/builtin_executor"
require "dev/cd"
require "dev/cli/ui"
require "dev/cli/usage_printer"
require "dev/command"
require "dev/command_executor"
require "dev/command_repository"
require "dev/command_service"
require "dev/credential_accessor"
require "dev/dependency_service"
require "dev/execution_context"
require "dev/global_catalog"
require "dev/group_executor"

module Dev
  # Early dispatch for the global builtins (see GlobalCatalog): runs before
  # Dev::Runner is constructed, so these commands work from any directory.
  # Project commands (`up`, yaml-declared names) keep the existing "must
  # find dev.yml" failure in the Runner path.
  #
  # A second composition root over the same command-tree machinery the
  # Runner uses: the global catalog is served by a CommandService over a
  # CommandRepository with no project half, so `dev plan status` resolves
  # down the tree exactly as it would inside a project, and a bare group
  # (`dev plan`) prints its usage. Help (bare `dev`, `--help`, `-h`,
  # `help`) is the Runner's everywhere: its tree lists these commands too.
  class GlobalDispatch
    extend T::Sig

    # Candidates shown in an ambiguous `dev cd` error before truncating.
    AMBIGUOUS_CANDIDATE_CAP = 10

    # Flag spellings that mean a global command: the conventional `--version`
    # is `dev version`. Normalized before classification and dispatch so the
    # catalog holds one entry per command.
    FLAG_SPELLINGS = T.let({ "--version" => "version" }.freeze, T::Hash[String, String])

    # @param catalog [Dev::GlobalCatalog] the global command tree
    # @param ui [Dev::Cli::Ui] the host half of the execution context (the
    #   global leaves print plainly, so the silent UI is the default)
    # @param out [IO, StringIO] where group usage prints
    sig { params(catalog: Dev::GlobalCatalog, ui: Dev::Cli::Ui, out: T.any(IO, StringIO)).void }
    def initialize(catalog: Dev::GlobalCatalog.new, ui: Dev::Cli::NoUi.new, out: $stdout)
      @catalog = catalog
      @ui = ui
      @out = out
    end

    # Whether the argv is dispatched here, before any dev.yml lookup: its
    # first token names a global builtin.
    #
    # @param argv [Array<String>]
    # @return [Boolean]
    sig { params(argv: T::Array[String]).returns(T::Boolean) }
    def global_command?(argv)
      cmd_name = normalize(argv).first
      !cmd_name.nil? && @catalog.commands.key?(cmd_name)
    end

    # Run a global builtin. Clean failures (usage errors, unresolved repos,
    # unknown subcommands) print to stderr and exit non-zero, mirroring the
    # Runner's CLI boundary.
    #
    # @param argv [Array<String>] full argv including the command name
    # @return [void]
    sig { params(argv: T::Array[String]).void }
    def run(argv)
      build_command_service.execute(normalize(argv), context: ExecutionContext.new(ui: @ui))
    rescue Dev::Cd::Matcher::AmbiguousRepoError => e
      print_ambiguous(e)
      Kernel.exit(1)
    rescue Dev::Cd::Accessor::ShellHookInactiveError
      # The accessor already explained the fix on stderr.
      Kernel.exit(1)
    rescue CommandRepository::CommandNotFoundError => e
      $stderr.puts "dev: #{e}"
      $stderr.puts "Run 'dev #{T.must(argv.first)}' to see its commands."
      Kernel.exit(1)
    rescue Dev::Cd::Matcher::RepoNotFoundError, Dev::CredentialAccessor::UsageError,
           ArgumentError, RuntimeError => e
      $stderr.puts "dev: #{e}"
      Kernel.exit(1)
    end

    private

    # The argv with a leading flag spelling replaced by its command name.
    #
    # @param argv [Array<String>]
    # @return [Array<String>]
    sig { params(argv: T::Array[String]).returns(T::Array[String]) }
    def normalize(argv)
      first = argv.first
      return argv if first.nil?

      [FLAG_SPELLINGS.fetch(first, first), *argv.drop(1)]
    end

    # The projectless service over the global catalog: builtins and groups
    # only (no project half, so no project or overridden executor arms).
    # Its root is never reached — global_command? admits only argv naming
    # a child — so it needs no epilogue.
    #
    # @return [CommandService]
    sig { returns(CommandService) }
    def build_command_service
      CommandService.new(
        repository: CommandRepository.new(
          root: CommandGroup.root(desc: "Global commands (available anywhere)", children: @catalog.commands),
          project_commands: {},
        ),
        executor: CommandExecutor.new(
          builtin_executor: BuiltinExecutor.new,
          group_executor: GroupExecutor.new(usage_printer: Cli::UsagePrinter.new, out: @out),
        ),
        dependency_service: NoProjectDependencyService.new,
      )
    end

    # Print an ambiguous `dev cd` result: the candidates (capped, each at its
    # shortest-unique depth) and the escape hatch — refine or Tab-browse.
    #
    # @param error [Dev::Cd::Matcher::AmbiguousRepoError]
    # @return [void]
    sig { params(error: Dev::Cd::Matcher::AmbiguousRepoError).void }
    def print_ambiguous(error)
      $stderr.puts "dev: #{error.message}:"
      shown = T.let(error.candidates.take(AMBIGUOUS_CANDIDATE_CAP), T::Array[String])
      shown.each { |candidate| $stderr.puts "  #{candidate}" }
      remaining = error.candidates.size - shown.size
      $stderr.puts "  … and #{remaining} more" if remaining.positive?
      $stderr.puts "dev: refine the query (e.g. org/repo) or press Tab to browse matches."
    end
  end
end
