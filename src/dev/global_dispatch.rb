# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/cd"
require "dev/plan"
require "dev/credentials"
require "dev/credential_accessor"

module Dev
  # Early dispatch for global builtins that must not require a dev.yml:
  #
  # - `dev cd`   — host-global (jumps between checkouts; also its hidden
  #                --resolve / --candidates plumbing)
  # - `dev cred` — host-global (credentials live under XDG / ~/.config/dev)
  # - `dev plan` — workspace-global (plans live in the enclosing workspace,
  #                no project config is read)
  #
  # Runs before Dev::Runner is constructed, so these commands work from any
  # directory. Project commands (`up`, yaml-declared names) keep the existing
  # "must find dev.yml" failure in the Runner path.
  class GlobalDispatch
    extend T::Sig

    GLOBAL_COMMANDS = T.let(%w[cd plan cred].freeze, T::Array[String])

    # Candidates shown in an ambiguous `dev cd` error before truncating.
    AMBIGUOUS_CANDIDATE_CAP = 10

    # @param cd_accessor [Dev::Cd::Accessor]
    # @param cred_accessor [Dev::CredentialAccessor]
    sig { params(cd_accessor: Dev::Cd::Accessor, cred_accessor: Dev::CredentialAccessor).void }
    def initialize(cd_accessor: Dev::Cd::Accessor.new, cred_accessor: Dev::CredentialAccessor.new)
      @cd_accessor = T.let(cd_accessor, Dev::Cd::Accessor)
      @cred_accessor = T.let(cred_accessor, Dev::CredentialAccessor)
    end

    # Whether the argv names a global builtin this dispatcher owns.
    #
    # @param argv [Array<String>]
    # @return [Boolean]
    sig { params(argv: T::Array[String]).returns(T::Boolean) }
    def global_command?(argv)
      GLOBAL_COMMANDS.include?(argv.first)
    end

    # Run a global builtin. Clean failures (usage errors, unresolved repos)
    # print to stderr and exit non-zero, mirroring the Runner's CLI boundary.
    #
    # @param argv [Array<String>] full argv including the command name
    # @return [void]
    sig { params(argv: T::Array[String]).void }
    def run(argv)
      args = T.let(argv.dup, T::Array[String])
      cmd_name = T.must(args.shift)
      case cmd_name
      when "cd" then @cd_accessor.run(args)
      # Plan::Accessor is built per run: its workspace root depends on the cwd.
      when "plan" then Dev::Plan::Accessor.new(project_root: workspace_root).run(args)
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
      cwd = Pathname.new(Dir.pwd)
      cwd.ascend do |path|
        return path if (path / Dev::DEV_YAML_FILENAME).exist?
      end
      cwd.ascend do |path|
        return path if (path / ".git").exist?
      end
      cwd
    end
  end
end
