# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/builtins/cd_command"
require "dev/builtins/clone_command"
require "dev/builtins/config_get_command"
require "dev/builtins/config_list_command"
require "dev/builtins/config_set_command"
require "dev/builtins/cred_get_command"
require "dev/builtins/engine_down_command"
require "dev/builtins/engine_status_command"
require "dev/builtins/engine_up_command"
require "dev/builtins/learnings_init_command"
require "dev/builtins/learnings_invariants_command"
require "dev/builtins/learnings_status_command"
require "dev/builtins/learnings_sync_command"
require "dev/builtins/plan_hook_after_edit_command"
require "dev/builtins/plan_init_command"
require "dev/builtins/plan_link_command"
require "dev/builtins/plan_new_command"
require "dev/builtins/plan_pull_command"
require "dev/builtins/plan_push_command"
require "dev/builtins/plan_status_command"
require "dev/builtins/version_command"
require "dev/cd"
require "dev/clone"
require "dev/command"
require "dev/config_accessor"
require "dev/credential_accessor"

module Dev
  # The global builtins — the commands that must not require a dev.yml:
  #
  # - `cd`        — host-global (jumps between checkouts; also its hidden
  #                 --resolve / --candidates plumbing)
  # - `clone`     — host-global (clones into the canonical checkout layout
  #                 under $DEV_CD_ROOT; on a fresh machine it runs before any
  #                 project exists)
  # - `config`    — host-global (settings live under XDG / ~/.config/dev)
  # - `cred`      — host-global (credentials live under XDG / ~/.config/dev)
  # - `plan`      — workspace-global (plans live in the enclosing workspace,
  #                 no project config is read)
  # - `learnings` — host-global (the machine cache of the knowledge repo
  #                 lives under XDG / ~/.local/share/dev)
  # - `version`   — binary-global (what this dev is, wherever it runs)
  #
  # Built in one place so the two composition roots that need it —
  # GlobalDispatch, which runs these from any directory, and the Runner,
  # which lists them in a project's help — can never disagree about what
  # exists or how it is described.
  class GlobalCatalog
    extend T::Sig

    # @param cd_accessor [Dev::Cd::Accessor]
    # @param clone_accessor [Dev::Clone::Accessor]
    # @param config_accessor [Dev::ConfigAccessor]
    # @param cred_accessor [Dev::CredentialAccessor]
    # @param out [IO, StringIO] where the leaves print
    sig do
      params(
        cd_accessor: Dev::Cd::Accessor,
        clone_accessor: Dev::Clone::Accessor,
        config_accessor: Dev::ConfigAccessor,
        cred_accessor: Dev::CredentialAccessor,
        out: T.any(IO, StringIO),
      ).void
    end
    def initialize(cd_accessor: Dev::Cd::Accessor.new, clone_accessor: Dev::Clone::Accessor.new,
                   config_accessor: Dev::ConfigAccessor.new, cred_accessor: Dev::CredentialAccessor.new,
                   out: $stdout)
      @cd_accessor = cd_accessor
      @clone_accessor = clone_accessor
      @config_accessor = config_accessor
      @cred_accessor = cred_accessor
      @out = out
      @commands = T.let(nil, T.nilable(T::Hash[String, Command]))
    end

    # The global command tree, keyed by top-level name. Built once per
    # catalog: the same instances serve dispatch and listing.
    #
    # @return [Hash{String => Command}]
    sig { returns(T::Hash[String, Command]) }
    def commands
      @commands ||= {
        "cd" => Builtins::CdCommand.new(accessor: @cd_accessor),
        "clone" => Builtins::CloneCommand.new(accessor: @clone_accessor),
        "config" => CommandGroup.new(
          path: ["config"],
          desc: "Manage dev settings",
          category: Command::Category::Workflow,
          children: {
            "list" => Builtins::ConfigListCommand.new(accessor: @config_accessor, out: @out),
            "get" => Builtins::ConfigGetCommand.new(accessor: @config_accessor, out: @out),
            "set" => Builtins::ConfigSetCommand.new(accessor: @config_accessor, out: @out),
          },
        ),
        "cred" => CommandGroup.new(
          path: ["cred"],
          desc: "Resolve stored credentials",
          category: Command::Category::Workflow,
          children: { "get" => Builtins::CredGetCommand.new(accessor: @cred_accessor, out: @out) },
        ),
        # The engine is machine state (one per user, shared by every
        # project), so its lifecycle is global; inside a project `up` sizes
        # it from the repo's hint.
        "engine" => CommandGroup.new(
          path: ["engine"],
          desc: "Manage the container engine (up | down | status)",
          category: Command::Category::Lifecycle,
          children: {
            "up" => Builtins::EngineUpCommand.new(out: @out),
            "down" => Builtins::EngineDownCommand.new(out: @out),
            "status" => Builtins::EngineStatusCommand.new(out: @out),
          },
        ),
        "learnings" => CommandGroup.new(
          path: ["learnings"],
          desc: "The learnings read path: org knowledge cache, skill links, invariants",
          category: Command::Category::Workflow,
          children: {
            "sync" => Builtins::LearningsSyncCommand.new(out: @out),
            "status" => Builtins::LearningsStatusCommand.new(out: @out),
            "invariants" => Builtins::LearningsInvariantsCommand.new(out: @out),
            "init" => Builtins::LearningsInitCommand.new(out: @out),
          },
        ),
        "plan" => CommandGroup.new(
          path: ["plan"],
          desc: "Sync Cursor plans with GitHub issues",
          category: Command::Category::Workflow,
          children: {
            "new" => Builtins::PlanNewCommand.new(out: @out),
            "link" => Builtins::PlanLinkCommand.new(out: @out),
            "pull" => Builtins::PlanPullCommand.new(out: @out),
            "push" => Builtins::PlanPushCommand.new(out: @out),
            "status" => Builtins::PlanStatusCommand.new(out: @out),
            "init" => Builtins::PlanInitCommand.new(out: @out),
            "hook-after-edit" => Builtins::PlanHookAfterEditCommand.new(out: @out),
          },
        ),
        # The binary's version is the binary's, wherever it runs; the host
        # reads it inside a container to decide whether to provision there.
        "version" => Builtins::VersionCommand.new(out: @out),
      }.freeze
    end
  end
end
