# typed: strict
# frozen_string_literal: true

require "set"
require "dev/label_contracts"
require "dev/reach"
require "dev/runner_group_contract"
require_relative "value_equality"

module Dev
  # What a runner is for: the one thing a registration declares. The
  # labels it advertises, the runner group its slots join, the host
  # obligations those labels carry (LabelContracts), its name and
  # directory, and its reach (Reach) all derive from the role.
  #
  # Three roles are builtin: `agent` (the agent labels, the pinned
  # `ai-flow` group), `orchestrator` (`ai-orchestrator`, its own pinned
  # group) and `build-host` (a repo's own label or `--labels`, no group).
  # A user role is declared in a repo's dev.yml (`runner_roles: { ue-farm:
  # { labels: [ue, gpu] } }`) and carries identity and labels only;
  # obligations stay builtin. User roles are repo-scoped.
  #
  # A role whose group carries a workflow pin is org-scoped, since only a
  # group can carry the pin; a build host is its repo's.
  #
  # Family identity is `(scope, host, role)`: a host plays each role at
  # most once per scope. An enrollment GitHub lists is matched to a role
  # by its labels (`claims?`); one GitHub has lost, by the pool its
  # `.runner` record names. Names and dirs are never parsed for this.
  class RunnerRole
    extend T::Sig
    include Dev::ValueEquality::Derived

    # A dev.yml role that cannot be: a builtin's name, an ai-flow label
    # (those roles are code's), or no labels at all.
    class DeclarationError < RuntimeError; end

    AGENT_NAME = "agent"
    ORCHESTRATOR_NAME = "orchestrator"
    BUILD_HOST_NAME = "build-host"

    # GitHub's default runner group, where a registration naming no group
    # lands; every repo-scoped registration records it.
    DEFAULT_POOL = "Default"

    sig { returns(String) }
    attr_reader :name

    sig { returns(T::Array[String]) }
    attr_reader :labels

    # The org-side contract the role's slots join; nil for a role whose
    # runners sit in Default.
    sig { returns(T.nilable(RunnerGroupContract)) }
    attr_reader :group

    # @param name [String]
    # @param labels [Array<String>]
    # @param group [Dev::RunnerGroupContract, nil]
    # @param builtin [Boolean]
    sig { params(name: String, labels: T::Array[String], group: T.nilable(RunnerGroupContract), builtin: T::Boolean).void }
    def initialize(name:, labels:, group: nil, builtin: false)
      @name = name
      @labels = labels
      @group = group
      @builtin = builtin
    end

    AGENT = T.let(
      new(name: AGENT_NAME, labels: LabelContracts::AI_FLOW_AGENT_LABELS, group: LabelContracts::AI_FLOW_GROUP, builtin: true),
      RunnerRole,
    )
    ORCHESTRATOR = T.let(
      new(name: ORCHESTRATOR_NAME, labels: [LabelContracts::ORCHESTRATOR_LABEL], group: LabelContracts::ORCHESTRATOR_GROUP, builtin: true),
      RunnerRole,
    )

    # The builtin roles `--role` may name. `build-host` is not among them:
    # it is what a registration is when no grouped role is asked for, and
    # its labels come from the repo or `--labels`, never from a name.
    BUILTINS = T.let({ AGENT_NAME => AGENT, ORCHESTRATOR_NAME => ORCHESTRATOR }.freeze, T::Hash[String, RunnerRole])

    class << self
      extend T::Sig

      # The builtin role of that name, or nil.
      #
      # @param name [String]
      # @return [Dev::RunnerRole, nil]
      sig { params(name: String).returns(T.nilable(RunnerRole)) }
      def builtin(name)
        BUILTINS[name]
      end

      # A build host: the repo's own runner (its label), or a custom
      # capability set, optionally in a human's group (`--group`).
      #
      # @param labels [Array<String>]
      # @param group [Dev::RunnerGroupContract, nil] a human's group; never a pinned one
      # @return [Dev::RunnerRole]
      sig { params(labels: T::Array[String], group: T.nilable(RunnerGroupContract)).returns(RunnerRole) }
      def build_host(labels:, group: nil)
        new(name: BUILD_HOST_NAME, labels: labels, group: group, builtin: true)
      end

      # A role declared in dev.yml.
      #
      # @param name [String]
      # @param labels [Array<String>]
      # @return [Dev::RunnerRole]
      # @raise [DeclarationError]
      sig { params(name: String, labels: T::Array[String]).returns(RunnerRole) }
      def user(name:, labels:)
        if BUILTINS.key?(name) || name == BUILD_HOST_NAME
          raise DeclarationError, "runner role '#{name}' is builtin — a dev.yml role needs another name"
        end
        raise DeclarationError, "runner role '#{name}' declares no labels" if labels.empty?

        reserved = labels & LabelContracts::AI_FLOW_LABELS
        unless reserved.empty?
          raise DeclarationError,
            "runner role '#{name}' claims #{reserved.join(",")} — ai-flow labels belong to the builtin roles " \
              "(#{BUILTINS.keys.join(", ")}); a dev.yml role names its own capabilities"
        end

        new(name: name, labels: labels)
      end

      # The role a label set means — the sugar behind `--ai-flow` and
      # `--labels`: any agent label is the agent role (with the labels
      # given, a partitioned topology's subset), the orchestrator label its
      # role, anything else a build host with those capabilities.
      #
      # @param labels [Array<String>]
      # @param group [Dev::RunnerGroupContract, nil] `--group`, for a build host
      # @return [Dev::RunnerRole]
      # @raise [ArgumentError] a set mixing the orchestrator label with an agent label
      sig { params(labels: T::Array[String], group: T.nilable(RunnerGroupContract)).returns(RunnerRole) }
      def for_labels(labels, group: nil)
        case LabelContracts.group_for(labels.join(","))
        when LabelContracts::AI_FLOW_GROUP
          new(name: AGENT_NAME, labels: labels, group: LabelContracts::AI_FLOW_GROUP, builtin: true)
        when LabelContracts::ORCHESTRATOR_GROUP
          ORCHESTRATOR
        else
          build_host(labels: labels, group: group)
        end
      end
    end

    sig { returns(T::Boolean) }
    def builtin?
      @builtin
    end

    # Whether the role's runners live at the org by construction: only a
    # group can carry the workflow pin, so a pinned role is org-scoped
    # because of the pin, not as an input.
    sig { returns(T::Boolean) }
    def org_scoped?
      group = @group
      !group.nil? && group.owned?
    end

    sig { returns(T::Boolean) }
    def build_host?
      @name == BUILD_HOST_NAME
    end

    # The runner group the role's slots record in `.runner` (`poolName`):
    # the contract's, else GitHub's Default — what tells a lost
    # enrollment's family.
    sig { returns(String) }
    def pool_name
      @group&.name || DEFAULT_POOL
    end

    # Slot 1's runner name on a host: `<host>-<role>` for a grouped or user
    # role, the bare host for a build host. Several roles may share a host
    # at one org scope and runner names are unique per scope, so the role
    # is part of the name.
    #
    # @param host [String] the hostname
    # @return [String]
    sig { params(host: String).returns(String) }
    def slot_base(host)
      build_host? ? host : "#{host}-#{@name}"
    end

    # What the default install dir is named after (`~/actions-runner-<suffix>`):
    # the role; for a build host, its first label sanitized. A path, never
    # identity — the `.runner` record inside is what binds a dir to anything.
    sig { returns(String) }
    def dir_suffix
      return @name unless build_host?

      sanitized = @labels.first.to_s.gsub(/[^A-Za-z0-9_.-]/, "-")
      sanitized.empty? ? "default" : sanitized
    end

    # Whether a runner advertising these labels is one of this role's: its
    # labels oblige this role's group, or no group at all (a bare set,
    # which any role amends into itself).
    #
    # @param labels [Array<String>] GitHub's labels for the runner
    # @return [Boolean]
    sig { params(labels: T::Array[String]).returns(T::Boolean) }
    def claims?(labels)
      obliged = LabelContracts.group_for(labels.join(","))
      obliged.nil? || obliged == @group
    rescue ArgumentError
      false
    end

    # Who may land a job on a slot of this role, for a registration made
    # for `target`. A pinned role reaches through its group's workflows:
    # the agent from the group's selected repos, the orchestrator from
    # every repo. A build host reaches its repo through any workflow, and
    # is refused for a public repo: an approved fork PR's workflow could
    # then run on the host.
    #
    # @param target [Dev::Reach::Target]
    # @return [Dev::Reach]
    # @raise [Dev::Reach::ExposedError]
    sig { params(target: Reach::Target).returns(Reach) }
    def expected_reach(target)
      labels = Set.new(@labels)
      if org_scoped?
        group = T.must(@group)
        repos = group.open? ? Reach::ALL : Set[target.repo]
        return Reach.new(repos: repos, workflows: Set.new(group.workflows), labels: labels)
      end

      if target.public
        raise Reach::ExposedError,
          "#{target.repo} is public and a #{@name} runner would take jobs from any of its workflows — an approved fork PR's " \
            "YAML could land on this host. Enroll for a private repo, or put the runners in a group " \
            "pinned to the workflows that may use them."
      end

      Reach.new(repos: Set[target.repo], workflows: Reach::ANY, labels: labels)
    end

    # @return [Array] the members that constitute identity
    sig { override.returns(T::Array[T.anything]) }
    def equality_members
      [@name, @labels, @group, @builtin]
    end
  end
end
