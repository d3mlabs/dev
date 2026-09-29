# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/builtins/cd_command"
require "dev/builtins/clone_command"
require "dev/builtins/config_command"
require "dev/builtins/cred_command"
require "dev/builtins/learnings_command"
require "dev/builtins/plan_command"
require "dev/cd"
require "dev/cli/global_usage_printer"
require "dev/clone"
require "dev/plan"
require "dev/learnings"
require "dev/config_accessor"
require "dev/credentials"
require "dev/credential_accessor"
require "dev/workspace_root"

module Dev
  # Early dispatch for global builtins that must not require a dev.yml:
  #
  # - `dev cd`        — host-global (jumps between checkouts; also its hidden
  #                     --resolve / --candidates plumbing)
  # - `dev clone`     — host-global (clones into the canonical checkout layout
  #                     under $DEV_CD_ROOT; on a fresh machine it runs before
  #                     any project exists)
  # - `dev config`    — host-global (settings live under XDG / ~/.config/dev)
  # - `dev cred`      — host-global (credentials live under XDG / ~/.config/dev)
  # - `dev plan`      — workspace-global (plans live in the enclosing
  #                     workspace, no project config is read)
  # - `dev learnings` — host-global (the machine cache of the knowledge repo
  #                     lives under XDG / ~/.local/share/dev)
  #
  # Runs before Dev::Runner is constructed, so these commands work from any
  # directory. Project commands (`up`, yaml-declared names) keep the existing
  # "must find dev.yml" failure in the Runner path.
  #
  # Help is a conditional citizen here: outside any dev.yml project, the help
  # spellings (bare `dev`, `--help`, `-h`, `help`) render the global usage —
  # inside a project they stay with the Runner, which lists the project's
  # catalog.
  class GlobalDispatch
    extend T::Sig

    # Global command name => description. One hash serves both dispatch
    # membership and the global usage listing; descriptions alias the
    # builtins' canonical DESC constants so the two help views cannot drift.
    GLOBAL_COMMANDS = T.let(
      {
        "cd" => Builtins::CdCommand::DESC,
        "clone" => Builtins::CloneCommand::DESC,
        "config" => Builtins::ConfigCommand::DESC,
        "cred" => Builtins::CredCommand::DESC,
        "learnings" => Builtins::LearningsCommand::DESC,
        "plan" => Builtins::PlanCommand::DESC,
      }.freeze,
      T::Hash[String, String],
    )

    # Candidates shown in an ambiguous `dev cd` error before truncating.
    AMBIGUOUS_CANDIDATE_CAP = 10

    # @param cd_accessor [Dev::Cd::Accessor]
    # @param clone_accessor [Dev::Clone::Accessor]
    # @param config_accessor [Dev::ConfigAccessor]
    # @param cred_accessor [Dev::CredentialAccessor]
    # @param usage_printer [Dev::Cli::GlobalUsagePrinter]
    sig do
      params(
        cd_accessor: Dev::Cd::Accessor,
        clone_accessor: Dev::Clone::Accessor,
        config_accessor: Dev::ConfigAccessor,
        cred_accessor: Dev::CredentialAccessor,
        usage_printer: Dev::Cli::GlobalUsagePrinter,
      ).void
    end
    def initialize(cd_accessor: Dev::Cd::Accessor.new, clone_accessor: Dev::Clone::Accessor.new,
                   config_accessor: Dev::ConfigAccessor.new, cred_accessor: Dev::CredentialAccessor.new,
                   usage_printer: Dev::Cli::GlobalUsagePrinter.new)
      @cd_accessor = cd_accessor
      @clone_accessor = clone_accessor
      @config_accessor = config_accessor
      @cred_accessor = cred_accessor
      @usage_printer = usage_printer
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
      return true if cmd_name && GLOBAL_COMMANDS.key?(cmd_name)

      help_argv?(argv) && WorkspaceRoot.nearest_dev_yaml.nil?
    end

    # Run a global builtin. Clean failures (usage errors, unresolved repos)
    # print to stderr and exit non-zero, mirroring the Runner's CLI boundary.
    #
    # @param argv [Array<String>] full argv including the command name
    # @return [void]
    sig { params(argv: T::Array[String]).void }
    def run(argv)
      if help_argv?(argv)
        @usage_printer.print(commands: GLOBAL_COMMANDS, out: $stdout)
        return
      end

      args = T.let(argv.dup, T::Array[String])
      cmd_name = T.must(args.shift)
      case cmd_name
      when "cd" then @cd_accessor.run(args)
      when "clone" then @clone_accessor.run(args)
      when "config" then @config_accessor.run(args)
      # Plan and Learnings accessors are built per run: their workspace root
      # depends on the cwd.
      when "plan" then Dev::Plan::Accessor.new(project_root: WorkspaceRoot.workspace).run(args)
      when "learnings" then Dev::Learnings::Accessor.new(project_root: WorkspaceRoot.enclosing_project).run(args)
      when "cred" then @cred_accessor.run(args)
      else raise ArgumentError, "not a global command: #{cmd_name}"
      end
    rescue Dev::Cd::Matcher::AmbiguousRepoError => e
      print_ambiguous(e)
      Kernel.exit(1)
    rescue Dev::Cd::Accessor::ShellHookInactiveError
      # The accessor already explained the fix on stderr.
      Kernel.exit(1)
    rescue Dev::Cd::Matcher::RepoNotFoundError, Dev::CredentialAccessor::UsageError,
           ArgumentError, RuntimeError => e
      $stderr.puts "dev: #{e}"
      Kernel.exit(1)
    end

    private

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
