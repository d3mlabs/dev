# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/builtin_executor"
require "dev/cd"
require "dev/cli/global_usage_printer"
require "dev/cli/ui"
require "dev/cli/usage_printer"
require "dev/command_executor"
require "dev/command_repository"
require "dev/command_service"
require "dev/credential_accessor"
require "dev/dependency_service"
require "dev/execution_context"
require "dev/global_catalog"
require "dev/group_executor"
require "dev/workspace_root"

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
  # (`dev plan`) prints its usage.
  #
  # Help is a conditional citizen here: outside any dev.yml project, the help
  # spellings (bare `dev`, `--help`, `-h`, `help`) render the global usage —
  # inside a project they stay with the Runner, which lists the project's
  # catalog.
  class GlobalDispatch
    extend T::Sig

    # Candidates shown in an ambiguous `dev cd` error before truncating.
    AMBIGUOUS_CANDIDATE_CAP = 10

    # @param catalog [Dev::GlobalCatalog] the global command tree
    # @param usage_printer [Dev::Cli::GlobalUsagePrinter]
    # @param ui [Dev::Cli::Ui] the host half of the execution context (the
    #   global leaves print plainly, so the silent UI is the default)
    # @param out [IO, StringIO] where usage prints
    sig do
      params(
        catalog: Dev::GlobalCatalog,
        usage_printer: Dev::Cli::GlobalUsagePrinter,
        ui: Dev::Cli::Ui,
        out: T.any(IO, StringIO),
      ).void
    end
    def initialize(catalog: Dev::GlobalCatalog.new, usage_printer: Dev::Cli::GlobalUsagePrinter.new,
                   ui: Dev::Cli::NoUi.new, out: $stdout)
      @catalog = catalog
      @usage_printer = usage_printer
      @ui = ui
      @out = out
    end

    # Whether the argv is dispatched here, before any dev.yml lookup: a
    # global builtin from anywhere, or a help spelling outside any project
    # (inside one, the Runner's help lists the project catalog instead).
    #
    # @param argv [Array<String>]
    # @return [Boolean]
    sig { params(argv: T::Array[String]).returns(T::Boolean) }
    def global_command?(argv)
      cmd_name = argv.first
      return true if cmd_name && @catalog.commands.key?(cmd_name)

      help_argv?(argv) && WorkspaceRoot.nearest_dev_yaml.nil?
    end

    # Run a global builtin. Clean failures (usage errors, unresolved repos,
    # unknown subcommands) print to stderr and exit non-zero, mirroring the
    # Runner's CLI boundary.
    #
    # @param argv [Array<String>] full argv including the command name
    # @return [void]
    sig { params(argv: T::Array[String]).void }
    def run(argv)
      if help_argv?(argv)
        @usage_printer.print(commands: @catalog.commands, out: @out)
        return
      end

      build_command_service.execute(argv, context: ExecutionContext.new(ui: @ui))
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

    # The projectless service over the global catalog: builtins and groups
    # only (no project half, so no project or overridden executor arms).
    #
    # @return [CommandService]
    sig { returns(CommandService) }
    def build_command_service
      CommandService.new(
        repository: CommandRepository.new(builtins: @catalog.commands, project_commands: {}),
        executor: CommandExecutor.new(
          builtin_executor: BuiltinExecutor.new,
          group_executor: GroupExecutor.new(usage_printer: Cli::UsagePrinter.new, out: @out),
        ),
        dependency_service: NoProjectDependencyService.new,
      )
    end

    # Whether the argv is a help spelling. Mirrors the Runner's routing:
    # bare `dev`, the exact conventional flags, and `help` as the command
    # name (the help builtin ignores trailing args).
    #
    # @param argv [Array<String>]
    # @return [Boolean]
    sig { params(argv: T::Array[String]).returns(T::Boolean) }
    def help_argv?(argv)
      argv.empty? || argv == ["--help"] || argv == ["-h"] || argv.first == "help"
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
