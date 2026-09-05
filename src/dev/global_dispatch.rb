# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/builtins/cd_command"
require "dev/builtins/clone_command"
require "dev/builtins/cred_command"
require "dev/builtins/learnings_command"
require "dev/builtins/plan_command"
require "dev/cd"
require "dev/cli/global_usage_printer"
require "dev/clone"
require "dev/plan"
require "dev/learnings"
require "dev/credentials"
require "dev/credential_accessor"

module Dev
  # Early dispatch for global builtins that must not require a dev.yml:
  #
  # - `dev cd`        — host-global (jumps between checkouts; also its hidden
  #                     --resolve / --candidates plumbing)
  # - `dev clone`     — host-global (clones into the canonical checkout layout
  #                     under $DEV_CD_ROOT; on a fresh machine it runs before
  #                     any project exists)
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
    # @param cred_accessor [Dev::CredentialAccessor]
    # @param usage_printer [Dev::Cli::GlobalUsagePrinter]
    sig do
      params(
        cd_accessor: Dev::Cd::Accessor,
        clone_accessor: Dev::Clone::Accessor,
        cred_accessor: Dev::CredentialAccessor,
        usage_printer: Dev::Cli::GlobalUsagePrinter,
      ).void
    end
    def initialize(cd_accessor: Dev::Cd::Accessor.new, clone_accessor: Dev::Clone::Accessor.new,
                   cred_accessor: Dev::CredentialAccessor.new,
                   usage_printer: Dev::Cli::GlobalUsagePrinter.new)
      @cd_accessor = cd_accessor
      @clone_accessor = clone_accessor
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

      help_argv?(argv) && nearest_dev_yaml_root.nil?
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
      # Plan and Learnings accessors are built per run: their workspace root
      # depends on the cwd.
      when "plan" then Dev::Plan::Accessor.new(project_root: workspace_root).run(args)
      when "learnings" then Dev::Learnings::Accessor.new(project_root: enclosing_project_root).run(args)
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

    # The workspace root for workspace-global commands: the nearest ancestor
    # with a dev.yml, else the nearest git repo root, else the cwd itself —
    # so `dev plan` works in any checkout, dev.yml or not.
    #
    # @return [Pathname]
    sig { returns(Pathname) }
    def workspace_root
      enclosing_project_root || Pathname.new(Dir.pwd)
    end

    # The enclosing project (nearest dev.yml, else nearest git root), or nil
    # when the cwd sits in no project at all — `dev learnings` outside any
    # checkout does only the machine-global work.
    #
    # @return [Pathname, nil]
    sig { returns(T.nilable(Pathname)) }
    def enclosing_project_root
      nearest_dev_yaml_root || nearest_git_root
    end

    # The nearest ancestor holding a dev.yml, or nil. This is the "inside a
    # project?" test the help fallback uses: a plain git checkout with no
    # dev.yml still gets the global usage.
    #
    # @return [Pathname, nil]
    sig { returns(T.nilable(Pathname)) }
    def nearest_dev_yaml_root
      Pathname.new(Dir.pwd).ascend do |path|
        return path if (path / Dev::DEV_YAML_FILENAME).exist?
      end
      nil
    end

    # @return [Pathname, nil] the nearest ancestor holding a .git, or nil
    sig { returns(T.nilable(Pathname)) }
    def nearest_git_root
      Pathname.new(Dir.pwd).ascend do |path|
        return path if (path / ".git").exist?
      end
      nil
    end
  end
end
