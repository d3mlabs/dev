# typed: strict
# frozen_string_literal: true

require "set"
require "dev/deps/dependency"
require "dev/enrolled_runner"
require "dev/lifecycle/project_version"
require "dev/reach"
require "dev/runner_group_contract"
require_relative "value_equality"

module Dev
  # What a runner is for: the one thing a registration declares. The
  # labels it advertises, the runner group its slots join, the job
  # identity its jobs run as, its name and directory, and its reach
  # (Reach) all derive from the role.
  #
  # One role is builtin: `build-host` — a repo's own label or `--labels`,
  # no group, no job identity. Every other role is **declared** in a
  # project's dev.yml (`runner_roles:`), which may give it a runner group
  # pinned to the project's own workflows (`group:` + `workflows:`) and a
  # job identity (`job_identity:`), the OS user its jobs run as
  # (JobIdentity). A declared role's pins are at the project's series —
  # `v<major>` from its VERSION — so the declaration names workflow paths
  # and is bound to the project's repo and version at register
  # (Declaration#bind). Which project declares which roles is that
  # project's business: dev knows none by name.
  #
  # A project may instead **reference** a role another project declares
  # (`runner_roles: agent: { from: d3mlabs/ai-flow }`, Reference): a lane
  # belongs to the project whose jobs run on it, and the shape it borrows
  # — labels, job identity — is read from the declaring project's dev.yml
  # at the version the referencing project's lock pins, never retyped. A
  # referenced role binds at repo scope only (Declaration#as_referenced).
  #
  # A role says nothing about what its jobs run: every slot's jobs run
  # the checkout they are given, and what that checkout needs — a
  # deployed tool among it — is its lock's, installed by the job's own
  # `dev up`. The role's verbs are enrollment acts.
  #
  # A role whose group carries a workflow pin is org-scoped, since only a
  # group can carry the pin; a build host is its repo's.
  #
  # Family identity is `(scope, host, role)`: a host plays each role at
  # most once per scope. An enrollment GitHub lists is matched to a role
  # by its labels (`claims?`); one GitHub has lost, by the pool its
  # `.runner` record names. Names and dirs are never parsed for this.
  # A slot inspected away from its declaring checkout is known by its
  # pool alone (`pooled`): the record says which group, not which role.
  class RunnerRole
    extend T::Sig
    include Dev::ValueEquality::Derived

    # A dev.yml role that cannot be: the builtin's name, no labels, a group
    # without the pin that makes it dev's to converge, a pin without a
    # group to carry it, a workflow path outside `.github/workflows/`, or
    # a project version no series can be read from.
    class DeclarationError < RuntimeError; end

    BUILD_HOST_NAME = "build-host"

    # Where docs/runners.md lays out which scope a registration gets for
    # which owner and visibility, and why a public repo at repo scope is
    # refused.
    SCOPE_DOC_URL = "https://github.com/d3mlabs/dev/blob/main/docs/runners.md#scope"

    # GitHub's default runner group, where a registration naming no group
    # lands; every repo-scoped registration records it.
    DEFAULT_POOL = "Default"

    # Where a project's reusable workflows live; a declared role pins paths
    # under it. GitHub's spelling of a pin is `<owner/repo>/<path>@<ref>`.
    WORKFLOWS_DIR = ".github/workflows/"

    # How a role came to be: the builtin build host, a dev.yml declaration,
    # a dev.yml reference to another project's declaration, or an
    # enrollment known by its pool alone.
    class Kind < T::Enum
      enums do
        BuildHost = new("build-host")
        Declared = new("declared")
        Referenced = new("referenced")
        Pooled = new("pooled")
      end
    end

    # A role as dev.yml states it, before the project it belongs to is
    # known: the workflow pins name paths in the project and are bound to
    # the project's repo and series at register (#bind). Everything else
    # is the role's as declared.
    class Declaration
      extend T::Sig
      include Dev::ValueEquality::Derived

      sig { returns(String) }
      attr_reader :name

      sig { returns(T::Array[String]) }
      attr_reader :labels

      # The org runner group the role's slots join; nil for a role in no group.
      sig { returns(T.nilable(String)) }
      attr_reader :group

      # The group's visibility, GitHub's spelling (RunnerGroupContract).
      sig { returns(String) }
      attr_reader :visibility

      # The project's own workflow paths the group is pinned to.
      sig { returns(T::Array[String]) }
      attr_reader :workflows

      # The OS user the role's jobs run as; nil for a role with no job identity.
      sig { returns(T.nilable(String)) }
      attr_reader :job_identity

      # @param name [String]
      # @param labels [Array<String>]
      # @param group [String, nil]
      # @param visibility [String]
      # @param workflows [Array<String>]
      # @param job_identity [String, nil]
      sig do
        params(
          name: String,
          labels: T::Array[String],
          group: T.nilable(String),
          visibility: String,
          workflows: T::Array[String],
          job_identity: T.nilable(String),
        ).void
      end
      def initialize(name:, labels:, group: nil, visibility: RunnerGroupContract::SELECTED, workflows: [], job_identity: nil)
        @name = name
        @labels = labels
        @group = group
        @visibility = visibility
        @workflows = workflows
        @job_identity = job_identity
      end

      # The role bound to its project: each workflow path pinned at the
      # project's repo and series tag (`<repo>/<path>@refs/tags/v<major>`).
      #
      # @param repo [String] the project's "owner/repo"
      # @param version [String, nil] the project's VERSION; needed only
      #   when the role pins workflows
      # @return [Dev::RunnerRole]
      # @raise [DeclarationError] when the role pins workflows and the
      #   project declares no semver version to take the series from
      sig { params(repo: String, version: T.nilable(String)).returns(RunnerRole) }
      def bind(repo:, version:)
        group_name = group
        contract = group_name && RunnerGroupContract.new(name: group_name, workflows: pins(repo, version), visibility: visibility)
        RunnerRole.declared(name: name, labels: labels, group: contract, job_identity: job_identity)
      end

      # The role as another project's reference binds it (Reference): the
      # shape a lane borrows — this role's labels and job identity — at
      # repo scope. No runner group, since a repo has none and the group is
      # the declaring project's org pool, registered by its owner. Nothing
      # of the declaring project's repo or version enters the role: the
      # version only chose which declaration was read; the lane's jobs run
      # the referencing checkout, whose lock installs the tool.
      #
      # @return [Dev::RunnerRole]
      sig { returns(RunnerRole) }
      def as_referenced
        RunnerRole.new(name: name, labels: labels, group: nil, job_identity: job_identity, kind: Kind::Referenced)
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [@name, @labels, @group, @visibility, @workflows, @job_identity]
      end

      private

      # @param repo [String]
      # @param version [String, nil]
      # @return [Array<String>] GitHub's spelling of each pin
      # @raise [DeclarationError]
      sig { params(repo: String, version: T.nilable(String)).returns(T::Array[String]) }
      def pins(repo, version)
        return [] if workflows.empty?

        series = series(version)
        workflows.map { |path| "#{repo}/#{path}@refs/tags/#{series}" }
      end

      # The project's series, from its VERSION — a release's
      # `major.minor.patch`, as every pin and deploy of the project reads it.
      #
      # @param version [String, nil] the project's VERSION
      # @return [Lifecycle::Series]
      # @raise [DeclarationError] when there is no semver version to take it from
      sig { params(version: T.nilable(String)).returns(Lifecycle::Series) }
      def series(version)
        if version.nil?
          raise DeclarationError,
            "runner role '#{name}' pins its workflows at the project's series (v<major>), but the project keeps no " \
              "#{Lifecycle::ProjectVersion::FILE_NAME} — declare one"
        end

        Lifecycle::ProjectVersion.series_tag(version)
        Lifecycle::Series.of(version)
      rescue Lifecycle::ProjectVersion::NotSemverError => e
        raise DeclarationError, "runner role '#{name}' pins its workflows at the project's series, but #{e.message}"
      end
    end

    # A role as dev.yml references it: another project's declaration of
    # the same name, named by that project's repo —
    #
    #   runner_roles:
    #     agent:
    #       from: d3mlabs/ai-flow
    #
    # The referencing project depends on the declaring one (a gh pin in its
    # lock), and the declaration is read from the declaring repo's dev.yml
    # at the version that pin holds (#pin), so the role a lane plays and
    # the tool its jobs run agree. What is borrowed is the declaration's
    # shape at repo scope (Declaration#as_referenced); an org pool is
    # declared and registered by its owner, never through a reference.
    class Reference
      extend T::Sig
      include Dev::ValueEquality::Derived

      # The referencing checkout's lock pins nothing from the declaring
      # repo: there is no version to read the declaration at.
      class NotDependedOnError < RuntimeError; end

      # The integration of the pin a reference is read through: the
      # declaring project installed as a gh tree.
      PIN_INTEGRATION = :gh

      # The pin metadata key naming the gh repo it came from.
      PIN_REPO_KEY = "repo"

      sig { returns(String) }
      attr_reader :name

      # The declaring project's repo, "owner/repo".
      sig { returns(String) }
      attr_reader :declaring_repo

      # @param name [String] the role's name, in both projects' dev.yml
      # @param declaring_repo [String] the declaring project's "owner/repo"
      # @raise [Dev::EnrolledRunner::MalformedRepoError] when the repo is not an owner and a name
      sig { params(name: String, declaring_repo: String).void }
      def initialize(name:, declaring_repo:)
        # The one owner/repo check dev has; the enrolled runner it derives
        # is not wanted, the refusal is.
        EnrolledRunner.for(declaring_repo)
        @name = name
        @declaring_repo = declaring_repo
      end

      # The pin the referencing checkout's lock holds for the declaring
      # project: whose version the declaration is read at.
      #
      # @param pins [Array<Dev::Deps::Dependency>] the referencing checkout's lock
      # @return [Dev::Deps::Dependency]
      # @raise [NotDependedOnError] when the lock pins nothing from the declaring repo
      sig { params(pins: T::Array[Deps::Dependency]).returns(Deps::Dependency) }
      def pin(pins)
        found = pins.find do |pin|
          pin.integration == PIN_INTEGRATION && pin.metadata[PIN_REPO_KEY].to_s.casecmp?(@declaring_repo)
        end
        return found if found

        raise NotDependedOnError,
          "runner role '#{@name}' is referenced from #{@declaring_repo}, but this checkout's lock pins nothing from it — " \
            "a referenced role is read at the version its project is installed at, so the role and the tool agree: " \
            "declare the dependency (`gh \"#{@declaring_repo}\", \"^1\"` in dependencies.rb) and run `dev deps update`"
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [@name, @declaring_repo]
      end
    end

    # What a `runner_roles:` entry is: a role declared here, or a reference
    # to one declared by another project.
    Entry = T.type_alias { T.any(Declaration, Reference) }

    sig { returns(String) }
    attr_reader :name

    sig { returns(T::Array[String]) }
    attr_reader :labels

    # The org-side contract the role's slots join; nil for a role whose
    # runners sit in Default.
    sig { returns(T.nilable(RunnerGroupContract)) }
    attr_reader :group

    # The OS user the role's jobs run as (JobIdentity converges it); nil
    # for a role whose jobs run as the runner user.
    sig { returns(T.nilable(String)) }
    attr_reader :job_identity

    # @param name [String]
    # @param labels [Array<String>]
    # @param group [Dev::RunnerGroupContract, nil]
    # @param job_identity [String, nil]
    # @param kind [Kind]
    sig { params(name: String, labels: T::Array[String], group: T.nilable(RunnerGroupContract), job_identity: T.nilable(String), kind: Kind).void }
    def initialize(name:, labels:, group:, job_identity:, kind:)
      @name = name
      @labels = labels
      @group = group
      @job_identity = job_identity
      @kind = kind
    end

    class << self
      extend T::Sig

      # A build host: the repo's own runner (its label), or a custom
      # capability set, optionally in a human's group (`--group`).
      #
      # @param labels [Array<String>]
      # @param group [Dev::RunnerGroupContract, nil] a human's group; never a pinned one
      # @return [Dev::RunnerRole]
      sig { params(labels: T::Array[String], group: T.nilable(RunnerGroupContract)).returns(RunnerRole) }
      def build_host(labels:, group: nil)
        new(name: BUILD_HOST_NAME, labels: labels, group: group, job_identity: nil, kind: Kind::BuildHost)
      end

      # A role a project declares (Declaration#bind, or a shipped alias).
      # Its group, when it has one, is dev's to converge, so it carries a
      # pin: an unpinned group is a human's, and a role in one is a build
      # host with `--group`.
      #
      # @param name [String]
      # @param labels [Array<String>]
      # @param group [Dev::RunnerGroupContract, nil]
      # @param job_identity [String, nil]
      # @return [Dev::RunnerRole]
      # @raise [DeclarationError]
      sig { params(name: String, labels: T::Array[String], group: T.nilable(RunnerGroupContract), job_identity: T.nilable(String)).returns(RunnerRole) }
      def declared(name:, labels:, group: nil, job_identity: nil)
        raise DeclarationError, "runner role '#{name}' is builtin — a dev.yml role needs another name" if name == BUILD_HOST_NAME
        raise DeclarationError, "runner role '#{name}' declares no labels" if labels.empty?
        if group && !group.owned?
          raise DeclarationError,
            "runner role '#{name}' names group '#{group.name}' but pins no workflows — a declared role's group is pinned to the " \
              "project's own workflows (workflows: [.github/workflows/<file>.yml]); a human's group is a build host's (--group)"
        end

        new(name: name, labels: labels, group: group, job_identity: job_identity, kind: Kind::Declared)
      end

      # A role known by its pool alone: slots in a runner group whose
      # declaration is not at hand (`dev runner status` away from the
      # declaring checkout). Named for the group; whether the group is
      # pinned — a declared role's — or a human's is GitHub's to say.
      #
      # @param pool [String] the group the slots' `.runner` records name
      # @param labels [Array<String>] GitHub's labels for the slot; empty when lost
      # @return [Dev::RunnerRole]
      sig { params(pool: String, labels: T::Array[String]).returns(RunnerRole) }
      def pooled(pool:, labels:)
        new(name: pool, labels: labels, group: RunnerGroupContract.new(name: pool), job_identity: nil, kind: Kind::Pooled)
      end

      # The role a slot plays, from its pool and GitHub's labels, among
      # the roles declared at hand: a declared role whose group is the
      # pool (an org slot), else one that claims the labels (a declared
      # role registered at its repo joins no group; a shared label keeps a
      # slot whose labels drifted in its family, where the drift is a
      # finding rather than a family that vanished); with no declaration
      # matching, a build host for a slot registered into no group, else a
      # pooled role. A lost slot has no labels left to read — GitHub was
      # their home.
      #
      # Two pools, because they answer different questions. `pool` is the
      # group GitHub has the slot in (falling back to the record's when
      # GitHub was not read): the group a declared role is matched by,
      # since `dev runner register` moves a slot between groups after
      # config.sh (RunnerGroups#place!) and the `.runner` record keeps the
      # name it was registered into. `registered` is that record's pool:
      # what dev registered the slot as — a build host names no group, so
      # one a human moved into a group of their own is a build host still,
      # not a role known by its pool alone.
      #
      # @param pool [String] the group GitHub has the slot in, else the record's `poolName`
      # @param labels [Array<String>, nil] GitHub's labels; nil when GitHub has lost the slot
      # @param declared [Hash{String => Dev::RunnerRole}] the roles declared at hand, by name
      # @param registered [String] the record's `poolName` (defaults to `pool`)
      # @return [Dev::RunnerRole]
      sig do
        params(pool: String, labels: T.nilable(T::Array[String]), declared: T::Hash[String, RunnerRole], registered: String)
          .returns(RunnerRole)
      end
      def for_slot(pool:, labels:, declared: {}, registered: pool)
        by_pool = pool == DEFAULT_POOL ? nil : declared.values.find { |role| role.pool_name == pool }
        return by_pool if by_pool

        by_labels = labels && declared.values.find { |role| role.claims?(labels) }
        return by_labels if by_labels
        return build_host(labels: labels || []) if registered == DEFAULT_POOL

        pooled(pool: pool, labels: labels || [])
      end
    end

    sig { returns(T::Boolean) }
    def build_host?
      @kind == Kind::BuildHost
    end

    sig { returns(T::Boolean) }
    def declared?
      @kind == Kind::Declared
    end

    # Whether the role was bound through a reference to another project's
    # declaration (Declaration#as_referenced): the checkout to re-register
    # it from is the one that references it.
    sig { returns(T::Boolean) }
    def referenced?
      @kind == Kind::Referenced
    end

    sig { returns(T::Boolean) }
    def pooled?
      @kind == Kind::Pooled
    end

    # The role as it enrolls at a repo: the same labels and identity, no
    # runner group. Runner groups partition an org's runners
    # and a repo has none — config.sh refuses a group name there — so a
    # declared role's group is its org-scope reach (`--org`) and nothing
    # else; a repo-scoped slot's reach is the repo's workflows.
    #
    # @return [Dev::RunnerRole] self when the role already has no group
    sig { returns(RunnerRole) }
    def at_repo_scope
      return self if @group.nil?

      self.class.new(name: @name, labels: @labels, group: nil, job_identity: @job_identity, kind: @kind)
    end

    # Whether the role has a pinned runner group of its own: registered at
    # the org (`--org`), its runners join that group and the group's pin
    # fixes which workflows reach them. Registered at a repo, the role is
    # that repo's like any other.
    sig { returns(T::Boolean) }
    def org_scoped?
      group = @group
      !group.nil? && group.owned?
    end

    # The runner group the role's slots record in `.runner` (`poolName`):
    # the contract's, else GitHub's Default — what tells a lost
    # enrollment's family.
    sig { returns(String) }
    def pool_name
      @group&.name || DEFAULT_POOL
    end

    # Slot 1's runner name on a host: `<host>-<role>` for a declared role,
    # the bare host for a build host. Several roles may share a host at
    # one org scope and runner names are unique per scope, so the role is
    # part of the name.
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

    # Whether a runner advertising these labels is one of this role's: it
    # shares a label with the role — an amend moves a family's labels
    # without losing the family; a set with nothing in common is another
    # family's at the same scope (the orchestrator pool beside the agent
    # slots).
    #
    # @param labels [Array<String>] GitHub's labels for the runner
    # @return [Boolean]
    sig { params(labels: T::Array[String]).returns(T::Boolean) }
    def claims?(labels)
      @labels.intersect?(labels)
    end

    # Who may land a job on a slot of this role, for a registration made
    # for `target`. Scope fixes the first clause: a pinned role registered
    # at its org reaches through its group's workflows — from the group's
    # selected repos, or from every repo when the group is open. Any role
    # registered at a repo — a build host always, a pinned role when the
    # repo keeps slots of its own — reaches that repo through any of its
    # workflows, and is refused for a public repo: an approved fork PR's
    # workflow could then run on the host.
    #
    # @param target [Dev::Reach::Target]
    # @return [Dev::Reach]
    # @raise [Dev::Reach::ExposedError]
    sig { params(target: Reach::Target).returns(Reach) }
    def expected_reach(target)
      labels = Set.new(@labels)
      if target.org_scoped && org_scoped?
        group = T.must(@group)
        repos = group.open? ? Reach::ALL : Set[target.repo]
        return Reach.new(repos: repos, workflows: Set.new(group.workflows), labels: labels)
      end

      if target.public
        raise Reach::ExposedError,
          "#{target.repo} is public and its #{@name} runners would take jobs from any of its workflows — an approved fork PR's " \
            "YAML could land on this host. Enroll for a private repo, or put the runners in a group " \
            "pinned to the workflows that may use them (#{SCOPE_DOC_URL})."
      end

      Reach.new(repos: Set[target.repo], workflows: Reach::ANY, labels: labels)
    end

    # @return [Array] the members that constitute identity
    sig { override.returns(T::Array[T.anything]) }
    def equality_members
      [@name, @labels, @group, @job_identity, @kind]
    end
  end
end
