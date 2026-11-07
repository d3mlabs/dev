# typed: strict
# frozen_string_literal: true

require "dev/command"
require "dev/confirmer"
require "dev/deps/lockfile"
require "dev/engine_provisioner"
require "dev/enrolled_runner"
require "dev/host_reach"
require "dev/label_contracts"
require "dev/linux_data_root_provisioner"
require "dev/project_manifest"
require "dev/runner_discovery"
require "dev/runner_family"
require "dev/runner_group_contract"
require "dev/runner_groups"
require "dev/runner_registry"
require "dev/runner_setup"
require "dev/runner_setup_config"
require "dev/runner_teardown"
require "dev/runner_user"

module Dev
  module Builtins
    # `dev runner register` — layers 3+4 of the machine doctrine (plans#26):
    # converge, then enroll. Scope and labels compose
    # orthogonally, with derived defaults so the common enrollments need no
    # declaration anywhere (the dev.yml `runner:` block is retired):
    #
    #   dev runner register                    # repo scope; label = the repo name
    #   dev runner register --labels ue-engine # repo scope, custom roles
    #   dev runner register --org --ai-flow    # org agent host, the full ai-flow set
    #   dev runner register --org --labels ai-build  # org custom pool
    #   dev runner register --org --ai-flow --slots 3  # three jobs at once
    #
    # A self-hosted runner runs one job at a time, so a host's concurrency
    # at a scope is how many runners it enrolls there (dev#470): `--slots
    # N` makes the enrollment a **family** of N (Dev::RunnerFamily) —
    # `<name>`, `<name>-2` .. `<name>-N`, each its own dir, `_work` and
    # service, every one carrying the same labels. Slot 1 is exactly the
    # enrollment register has always made, so a host from before slots is
    # a family of one; re-running without `--slots` keeps the size it
    # finds, a smaller `--slots` retires the surplus (asked first), a
    # larger one adds. Which repos may use an org family is the runner
    # group it sits in (Dev::RunnerGroups): the labels' contract names it
    # (any ai-flow label → the `ai-flow` group dev owns and pins, see
    # LabelContracts::AI_FLOW_GROUP) or `--group` does (a human's), and
    # the repo this registration is for — the checkout's, the same
    # derivation as the org and the label — is admitted to it. The act
    # that makes a repo exclusive is the repo-scoped registration itself:
    # when one carries labels an org group serves and the repo is among
    # that group's repos, register asks whether this runner should be its
    # only one and takes it out of the group on yes. So a repo's
    # concurrency on a host is the runners it can see, nothing declared
    # anywhere and nothing to remember; and a public repo only ever sees
    # a pinned group.
    #
    # register is idempotent and self-healing: when the enclosing checkout's
    # lock pins an image, it first brings the engine up for that
    # repo's resources hint — the same EngineProvisioner step as `dev up`,
    # for the invoking user, on every OS (the runner runs as that user, as
    # GitHub's config.sh/svc.sh do; sizes ratchet across the repos a host
    # serves). Then it converges every advertised label's contract
    # (agent-capability labels carry the agent host bootstrap; bare labels
    # converge nothing), then looks for an existing
    # enrollment at the target scope (RunnerDiscovery — every local runner
    # dir, so dir names never matter) and amends its labels in place on
    # GitHub (RunnerRegistry) instead of re-enrolling; only a scope nothing
    # serves gets the full enrollment ceremony (RunnerSetup).
    #
    # Before amending, register checks that the enrollment on disk is the
    # one serving GitHub (#238). Two signs it is not: more than one local
    # enrollment for the scope (the aftermath of `config.sh --replace` —
    # the newest dir holds the registration, an older one the service
    # unit, neither runs), or GitHub listing the runner offline (the
    # registration is held but nothing runs it). Either way register lists
    # the enrollments and asks to unregister them all and enroll fresh;
    # `--yes` answers for it; "no" changes nothing and prints the
    # `dev runner unregister` commands to do it by hand. One enrollment,
    # online, is the steady state and stays silent.
    #
    # On Linux the enrollment is the **runner user's**, by rule (dev#310,
    # RunnerUser): before anything enrolls, register converges the shared
    # data root and the runner user (`runner`; `--as` renames it) in one
    # sudo session, and refuses — naming the one `gh auth login` command —
    # while that user has no gh login, since every job on the host fetches
    # as it. Enrollments are looked for under both homes; one owned by
    # anyone but the runner user (the operator's own, from before the
    # rule) is drift and takes the same retire-and-enroll-fresh path as a
    # superseded one, torn down as its owner and enrolled as the runner
    # user. With a checkout, the runner user's reach over its lock — every
    # `gh` pin's repo, every image's floor package — is checked before
    # enrolling (HostReach); a grant it lacks is this command's message,
    # not a red run an hour in. macOS has no runner user and register runs
    # as it always has.
    #
    # Enrollment state is inspected, never recorded: the labels live on
    # GitHub, the scope in the runner dir's own .runner record — nothing in
    # dev.yml, Settings, or any inventory file.
    #
    # `--org` needs no project; bare register runs inside the checkout it
    # enrolls (its `engine:` hint sizes the engine) and makes that repo's
    # **enrolled runner** (Dev::EnrolledRunner): repo scope, the repo's
    # name as label — the GitHub spelling, lowercased, since a repo-scoped
    # runner is that repo's object and the workflows targeting it live
    # there; dev.yml `name:` is the package identity and may differ. That
    # enrollment is what the lifecycle verbs' remote dispatch targets from
    # a machine that is not a build's environment, found through the same
    # derivation over the Actions API (Dev::EnrolledRunnerLookup).
    # `--dir`/`--name`/`--repo` override the enrollment identity (`--repo`
    # moves the label with it); `--agent-user` the ai-agent default run-as
    # user. A leaf of the `runner` group (RunnerStatusCommand and
    # RunnerUnregisterCommand are the others).
    class RunnerRegisterCommand < BuiltinCommand
      extend T::Sig

      # The operator declined to unregister the superseded enrollments, so
      # register did not enroll: the message carries the by-hand remedy.
      # A RuntimeError so the CLI boundary prints it and exits 1.
      class SupersededEnrollmentsError < RuntimeError; end

      # The operator declined to unregister the slots past `--slots N`, so
      # register changed nothing: the message carries the by-hand remedy.
      class SurplusSlotsError < RuntimeError; end

      ORG_FLAG = "--org"
      LABELS_FLAG = "--labels"
      AI_FLOW_FLAG = "--ai-flow"
      SLOTS_FLAG = "--slots"
      GROUP_FLAG = "--group"

      # Where config.sh puts a registration naming no group: GitHub's own
      # default runner group, present in every org.
      DEFAULT_GROUP = "Default"
      DIR_FLAG = "--dir"
      NAME_FLAG = "--name"
      REPO_FLAG = "--repo"
      AGENT_USER_FLAG = "--agent-user"
      AS_FLAG = "--as"
      YES_FLAG = "--yes"

      # A family's enrollments by slot: the dirs enrolled under each slot's
      # name (one is the steady state; more are `--replace` leftovers).
      SlotMap = T.type_alias { T::Hash[Integer, T::Array[Dev::RunnerDiscovery::Enrollment]] }

      # Builds the RunnerSetup for the resolved config and flags; injected
      # so tests can observe the wiring without touching gh or the host.
      RunnerSetupFactory = T.type_alias do
        T.proc.params(
          config: RunnerSetupConfig,
          repo: T.nilable(String),
          org: T::Boolean,
          runner_user: T.nilable(Dev::RunnerUser),
        ).returns(Dev::RunnerSetup)
      end

      # The host rule: the runner user for this host (nil off Linux), given
      # what `--as` named; injected for tests.
      RunnerUserFactory = T.type_alias { T.proc.params(name: T.nilable(String)).returns(T.nilable(Dev::RunnerUser)) }

      # The checkout's lock, as the reach check reads it; injected for tests.
      PinsReader = T.type_alias { T.proc.params(root: Pathname).returns(T::Array[Dev::Deps::Dependency]) }

      # The reach check for an identity; injected for tests.
      ReachFactory = T.type_alias { T.proc.params(identity: Dev::RunnerUser).returns(Dev::HostReach) }

      # Resolves the advertised labels' contracts; injected for tests.
      ContractsFactory = T.type_alias do
        T.proc.params(
          labels: String,
          agent_user: T.nilable(String),
        ).returns(T::Array[Dev::LabelContracts::AgentHostContract])
      end

      # Answers "owner/repo" for the enclosing checkout, or echoes the
      # `--repo` override; the gh boundary behind the derived label.
      RepoResolver = T.type_alias { T.proc.params(override: T.nilable(String)).returns(String) }

      sig do
        params(
          runner_setup_factory: RunnerSetupFactory,
          contracts_factory: ContractsFactory,
          repo_resolver: RepoResolver,
          discovery: Dev::RunnerDiscovery,
          registry: T.untyped,
          teardown: Dev::RunnerTeardown,
          confirmer: Dev::Confirmer,
          engine_provisioner: Dev::EngineProvisioner,
          runner_user_factory: RunnerUserFactory,
          data_root_provisioner: T.nilable(Dev::LinuxDataRootProvisioner),
          pins_reader: PinsReader,
          reach_factory: ReachFactory,
          out: T.any(IO, StringIO),
          groups: T.nilable(Dev::RunnerGroups),
        ).void
      end
      def initialize(
        runner_setup_factory: ->(config, repo, org, runner_user) {
          Dev::RunnerSetup.new(config:, repo:, org:, as_user: runner_user&.name, home: runner_user&.home, path: runner_user&.path)
        },
        contracts_factory: ->(labels, agent_user) { Dev::LabelContracts.for(labels, agent_user: agent_user) },
        repo_resolver: ->(override) { override || Dev::RunnerSetup.current_repo },
        discovery: Dev::RunnerDiscovery.new,
        # The GitHub boundary (#find/#amend!); T.untyped so tests fake it.
        registry: Dev::RunnerRegistry.new,
        # `dev runner unregister`'s implementation, for superseded enrollments.
        teardown: Dev::RunnerTeardown.new(discovery: discovery),
        # Asks before unregistering anything.
        confirmer: Dev::Confirmer.new,
        # `dev up`'s engine step, run here for the checked-out repo's hint.
        engine_provisioner: Dev::EngineProvisioner.new,
        # The host rule (Linux: a runner user; elsewhere nil).
        runner_user_factory: ->(name) { Dev::RunnerUser.for_host(name: name) },
        # The shared data root the runner user joins; nil off Linux.
        data_root_provisioner: Dev::LinuxDataRootProvisioner.for_host,
        pins_reader: ->(root) { Dev::Deps::Lockfile.new(dir: root).read },
        reach_factory: ->(identity) { Dev::HostReach.new(identity: identity) },
        out: $stdout,
        # The org's runner groups, converged over the same registry.
        groups: nil
      )
        super()
        @groups = T.let(groups || Dev::RunnerGroups.new(registry: registry, out: out), Dev::RunnerGroups)
        @runner_setup_factory = runner_setup_factory
        @contracts_factory = contracts_factory
        @repo_resolver = repo_resolver
        @discovery = discovery
        @registry = registry
        @teardown = teardown
        @confirmer = confirmer
        @engine_provisioner = engine_provisioner
        @runner_user_factory = runner_user_factory
        @data_root_provisioner = data_root_provisioner
        @pins_reader = pins_reader
        @reach_factory = reach_factory
        @out = out
      end

      # The summary line, then what the operator needs at the prompt: who
      # does what in a registration, the Linux runner-user rule, the one
      # login command, the examples.
      sig { override.returns(String) }
      def desc
        <<~DESC
          Enroll this host as a self-hosted runner, converging label contracts (--org, --labels, --ai-flow)

          Converges (engine, label contracts), then enrolls — or amends an existing
          enrollment's labels in place. Re-running is the idempotent no-op and the
          drift repair.

          Concurrency is the runner layer's: a self-hosted runner runs one job at a
          time, so a host that should run N jobs at once at a scope enrolls N slots
          (--slots N) — <name>, <name>-2 .. <name>-N, one dir and service each, the
          same labels on all. Re-running keeps the size it finds; a smaller --slots
          retires the surplus (asked first). Which repos may use an org host's slots is
          their runner group, and the repo this registration is for — the checkout's,
          or --repo's — is admitted to it. ai-flow labels sit in the '#{LabelContracts::AI_FLOW_GROUP.name}' group,
          which dev owns: created when missing, pinned to ai-flow's workflows (plans#5
          H3), healed when the console drifted — nothing to remember. --group names a
          human's group for other pools. A public repo may only use a pinned group;
          register refuses otherwise. A repo-scoped enrollment is that repo's alone
          (cellbound-3d's editor); its concurrency is its own --slots — and when the repo
          may also use the org's slots for the same labels, register asks whether this
          runner should be its only one, taking it out of the group on yes.

          Three identities meet in a registration:
            you (gh auth)         mints the registration token — repo admin, or admin:org with --org
            the runner user       owns the enrollment: the dir, config.sh's record, and the gh login
                                  every job on this host fetches private dependencies with
            root (sudo)           installs the service unit
          and a job writes to its own repo with its GITHUB_TOKEN, never with a host login.

          On Linux the runner user is `#{Dev::RunnerUser::DEFAULT_NAME}` by rule (--as renames it): created if absent, in
          docker and #{LinuxDataRootProvisioner::GROUP}, no password, no sudo; its commands and every job run on the
          host PATH (brew's bin and sbin, then the system's — nothing of yours), and
          Homebrew's shellenv lands in #{Dev::RunnerUser::PROFILE_D} so `sudo -iu` shells
          find gh. Jobs upgrade dev through brew, and brew is single-owner, so
          brew's prefix is the runner user's: register hands it over (one chown,
          announced) when someone else owns it; a package by hand on the host is then
          `sudo -iu #{Dev::RunnerUser::DEFAULT_NAME} brew ...`. Brew loads nothing from a tap
          its user has not trusted, and trust is per user, so register also has the
          runner user trust the deployment's tap (`brew trust --tap <tap>`, as that user).
          Register needs the runner user logged in to gh — the machine user's token,
          #{Dev::RunnerUser.token_hint}
          (repo: the private fetches, under two owners; read:org: gh's own gate;
          read:packages: the same login pulls from ghcr) — and asks for it, input
          hidden, the first time; headless it prints the command instead and stops:
            #{Dev::RunnerUser.new(name: Dev::RunnerUser::DEFAULT_NAME).login_command}
          An enrollment running as anyone else is drift: register offers to retire it
          and enroll fresh as the runner user. On macOS the enrollment is yours (a
          per-user LaunchAgent); the agent user is the second identity there, and its
          own brew user — register has it trust the deployment's tap the same way.

          Examples:
            dev runner register                      # repo scope; label = the repo name
            dev runner register --labels ue-engine   # repo scope, custom roles
            dev runner register --org --ai-flow      # org agent host, the full ai-flow set
            dev runner register --org --labels ai-build
            dev runner register --org --ai-flow --slots 3    # three jobs at once; this repo may use them
            dev runner register --ai-flow                    # this repo's own agent runner; asks to leave the org's pool
            dev runner register --org --labels ue-engine --group ue-hosted   # a human's pool
        DESC
      end

      sig { override.returns(Command::Category) }
      def category = Command::Category::Environment

      sig { override.returns(T::Array[Cli::Flag]) }
      def flags
        [
          Cli::Flag.new(ORG_FLAG, desc: "enroll at the org scope (needs admin:org); labels are required"),
          Cli::Flag.new(LABELS_FLAG, takes_value: true, desc: "comma-separated labels; default: the repo's name"),
          Cli::Flag.new(AI_FLOW_FLAG, desc: "the full ai-flow label set (#{LabelContracts::AI_FLOW_LABELS.join(",")})"),
          Cli::Flag.new(SLOTS_FLAG, takes_value: true, desc: "how many jobs this host runs at once at this scope: N runners, <name>, <name>-2 .. <name>-N; default: what is enrolled, else 1"),
          Cli::Flag.new(GROUP_FLAG, takes_value: true, desc: "--org: the runner group the slots join (made once in the org's settings); ai-flow labels imply '#{LabelContracts::AI_FLOW_GROUP.name}'; default: #{DEFAULT_GROUP}"),
          Cli::Flag.new(DIR_FLAG, takes_value: true, desc: "the runner directory (one slot); default: actions-runner-<first label> under the enrollment owner's home, -<n> per further slot"),
          Cli::Flag.new(NAME_FLAG, takes_value: true, desc: "the runner's name on GitHub (slot 1; further slots are <name>-<n>); default: the hostname"),
          Cli::Flag.new(REPO_FLAG, takes_value: true, desc: "enroll for owner/repo instead of the enclosing checkout"),
          Cli::Flag.new(AGENT_USER_FLAG, takes_value: true, desc: "the OS user agent labels run the agent as; default: #{AgentBootstrap::DEFAULT_AGENT_USER}"),
          Cli::Flag.new(AS_FLAG, takes_value: true, desc: "Linux: the OS user the runner service runs as; default: #{Dev::RunnerUser::DEFAULT_NAME}"),
          Cli::Flag.new(YES_FLAG, desc: "answer yes without asking: unregister superseded enrollments and surplus slots, leave the org's pool"),
        ]
      end

      # Converge, then enroll (or amend) every slot, then the steps the
      # enrollment enables.
      sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
      def call(args:, context:)
        org = args.flag?(ORG_FLAG)
        labels = resolve_labels(args, context, org)
        slots = resolve_slots(args)
        contract = resolve_group(args, labels, org)
        config = RunnerSetupConfig.new(
          labels: labels,
          dir: args.value(DIR_FLAG),
          name: args.value(NAME_FLAG),
          group: contract&.name,
        )

        container = context.project&.project_images&.containerized? || false
        engine = context.project&.engine
        # The engine this host will build in, sized for this repo, before any
        # label contract (whose agent-host steps assume an engine exists).
        @engine_provisioner.provision!(resources: engine) if container

        # The host rule: who the enrollment belongs to. Its sudo work rides
        # the engine step's session; its gh login gates everything after;
        # and with a checkout, what that login can read of its lock is
        # checked now rather than discovered by a red run (HostReach).
        runner_user = @runner_user_factory.call(args.value(AS_FLAG))
        if runner_user
          @data_root_provisioner&.provision!
          runner_user.converge!
          runner_user.ensure_gh_authenticated!(ask: ->(question) { context.ui.ask_secret(question) })
          root = context.project&.root
          @reach_factory.call(runner_user).check!(@pins_reader.call(root)) if root
        end

        contracts = @contracts_factory.call(labels, args.value(AGENT_USER_FLAG))
        contracts.each do |contract|
          contract.converge!(
            container: container,
            cpus: engine&.cpus,
            memory_gib: engine&.memory_gib,
            disk_gib: engine&.disk_gib,
          )
        end

        setup = @runner_setup_factory.call(config, args.value(REPO_FLAG), org, runner_user)
        scope = setup.resolve_scope
        yes = args.flag?(YES_FLAG)
        # The org-side contract first: the group the slots will join must
        # exist, with its access, before config.sh names it.
        group = contract && @groups.converge!(contract, org: scope)
        # --dir is the operator picking the dir: no discovery, no detection.
        # The runner user's home is where the rule puts enrollments; the
        # operator's is where the ones from before it are.
        discovery = runner_user ? @discovery.also_under(runner_user.home) : @discovery
        enrollments = config.dir ? [] : discovery.enrollments_for(scope)
        family = resolve_family(enrollments, config, setup, slots)
        by_slot, runners = family_members(scope, enrollments, family, config)

        if superseded?(enrollments, by_slot, runners, runner_user)
          retire!(scope, enrollments, by_slot, runners, runner_user, yes: yes)
          by_slot = {}
          runners = {}
        end

        # The family's size: what --slots says, else what is enrolled (its
        # highest slot — a gap is re-filled), else one.
        count = slots || by_slot.keys.max || 1
        retire_surplus!(scope, by_slot.select { |slot, _dirs| slot > count }.values.flatten, yes: yes)

        (1..count).each do |slot|
          enrollment = by_slot[slot]&.first
          runner = enrollment && runners[enrollment.name]
          if enrollment && runner
            amend_enrollment(scope, enrollment, runner, config)
            @groups.place!(group, runner, org: scope) if group
            contracts.each { |contract| contract.after_enroll!(runner_dir: enrollment.dir) }
            next
          end

          slot_setup = setup
          if enrollment || slot > 1
            # GitHub has lost this enrollment (or --name renames it): the
            # re-enrollment reuses the discovered dir, never a second one.
            # A slot beyond the first takes the family's name and dir.
            slot_config = RunnerSetupConfig.new(
              labels: labels,
              dir: enrollment&.dir || family.slot_dir(slot),
              name: config.name || family.slot_name(slot),
              group: config.group,
            )
            slot_setup = @runner_setup_factory.call(slot_config, args.value(REPO_FLAG), org, runner_user)
          end
          slot_setup.run
          contracts.each { |contract| contract.after_enroll!(runner_dir: slot_setup.resolve_dir) }
        end

        if org
          converge_access!(scope, group, args.value(REPO_FLAG))
        else
          offer_exclusivity!(scope, labels, yes: yes)
        end
      end

      private

      # Who may use the family (dev#470: a repo's concurrency on a host is
      # the runners it can see): the repo this registration is for — the
      # checkout's, or `--repo`'s, the same derivation as the org and the
      # label — is admitted to the family's group. Slots naming no group
      # sit in GitHub's Default, so that is the group converged for them.
      #
      # @param scope [String] the org
      # @param group [Dev::RunnerRegistry::Group, nil] the contract's group, when one was obliged
      # @param repo_override [String, nil] `--repo`
      sig { params(scope: String, group: T.nilable(Dev::RunnerRegistry::Group), repo_override: T.nilable(String)).void }
      def converge_access!(scope, group, repo_override)
        access = group || @registry.group(org: scope, name: DEFAULT_GROUP)
        return if access.nil?

        @groups.admit!(access, @repo_resolver.call(repo_override), org: scope)
      end

      # The exclusion, derived (dev#470): a repo-scoped runner is that
      # repo's alone, so when its labels are ones an org group serves and
      # the repo may use that group too, the two pool — its jobs land on
      # either. That may be wanted (extra capacity) or not (cellbound-3d's
      # one editor must not also run on the org's slots), so register asks,
      # every run, and takes the repo out of the group on yes. Nothing
      # without a contract, without the group, or when the org cannot be
      # read with this login (a repo admin need not be an org admin).
      #
      # @param scope [String] the repo, "owner/repo"
      # @param labels [String] comma-separated labels (config.sh shape)
      # @param yes [Boolean] `--yes`
      sig { params(scope: String, labels: String, yes: T::Boolean).void }
      def offer_exclusivity!(scope, labels, yes:)
        contract = LabelContracts.group_for(labels)
        return unless contract

        org = T.must(scope.split("/").first)
        group = @registry.group(org: org, name: contract.name)
        return unless group&.selected?
        return unless @registry.group_repositories(org: org, group_id: group.id).any? { |selected| selected.full_name.casecmp?(scope) }

        @out.puts ">>> #{scope} may also use the org's '#{group.name}' runners for these labels — its jobs would land on either."
        unless yes || @confirmer.confirm?("Make this host's runner its only one?")
          @out.puts ">>> Left as is: #{scope} keeps using the org's '#{group.name}' runners too."
          return
        end

        @groups.exclude!(group, scope, org: org)
      rescue RunnerRegistry::QueryError => e
        @out.puts ">>> Could not read #{org}'s runner groups (#{e.message}) — whether #{scope} also uses the org's runners is unchecked."
      end

      # `--slots N`: the family's size, a positive integer; nil leaves it
      # to what is enrolled. More than one slot in one `--dir` is a
      # contradiction — every slot is its own dir.
      #
      # @param args [Cli::ParsedArgs]
      # @return [Integer, nil]
      # @raise [ArgumentError]
      sig { params(args: Cli::ParsedArgs).returns(T.nilable(Integer)) }
      def resolve_slots(args)
        raw = args.value(SLOTS_FLAG)
        return nil if raw.nil?

        slots = begin
          Integer(raw)
        rescue ArgumentError
          raise ArgumentError, "--slots takes a positive integer, not #{raw.inspect}"
        end
        raise ArgumentError, "--slots takes a positive integer, not #{raw.inspect}" if slots < 1
        raise ArgumentError, "--dir names one slot's dir — drop it to enroll #{slots} slots (each gets its own)" if slots > 1 && args.value(DIR_FLAG)

        slots
      end

      # The runner group the slots join, as a contract: what the labels
      # oblige (any ai-flow label → the ai-flow group dev owns), else what
      # `--group` names (a human's group; must exist), else none — the
      # slots land in Default. An org-scope matter: a repo-scoped runner
      # is that repo's alone. `--ai-flow --group x` is the contradiction
      # `--ai-flow --labels x` is: the shortcut already names its group.
      #
      # @param args [Cli::ParsedArgs]
      # @param labels [String] comma-separated labels (config.sh shape)
      # @param org [Boolean]
      # @return [Dev::RunnerGroupContract, nil]
      # @raise [ArgumentError]
      sig { params(args: Cli::ParsedArgs, labels: String, org: T::Boolean).returns(T.nilable(RunnerGroupContract)) }
      def resolve_group(args, labels, org)
        named = args.value(GROUP_FLAG)
        raise ArgumentError, "runner groups partition an org's runners — #{GROUP_FLAG} goes with #{ORG_FLAG}" if named && !org
        return nil unless org

        obliged = LabelContracts.group_for(labels)
        if named && obliged && named != obliged.name
          raise ArgumentError,
            "ai-flow labels sit in the '#{obliged.name}' runner group (pinned to ai-flow's workflows) — drop #{GROUP_FLAG} #{named}"
        end

        obliged || (named && RunnerGroupContract.new(name: named))
      end

      # The family this registration converges: named by `--name`, else by
      # the one base the discovered enrollments share, else the hostname —
      # the base being slot 1's name. Slot 1's dir is its enrollment's
      # when one exists, else the setup's default (`--dir` included).
      #
      # @param enrollments [Array<Dev::RunnerDiscovery::Enrollment>]
      # @param config [Dev::RunnerSetupConfig]
      # @param setup [Dev::RunnerSetup]
      # @param slots [Integer, nil]
      # @return [Dev::RunnerFamily]
      sig do
        params(
          enrollments: T::Array[Dev::RunnerDiscovery::Enrollment],
          config: RunnerSetupConfig,
          setup: Dev::RunnerSetup,
          slots: T.nilable(Integer),
        ).returns(Dev::RunnerFamily)
      end
      def resolve_family(enrollments, config, setup, slots)
        bases = enrollments.map { |enrollment| Dev::RunnerFamily.base_of(enrollment.name) }.uniq
        # The hostname is asked for only when a second slot has to be
        # named from it: a lone fresh enrollment keeps the setup's own
        # derivation, as it always has.
        base = config.name || (bases.length == 1 ? T.must(bases.first) : nil) || (slots.to_i > 1 ? setup.resolve_name : "")
        provisional = Dev::RunnerFamily.new(base: base, dir: setup.resolve_dir)
        first = enrollments.find { |enrollment| provisional.slot_of(enrollment.name) == 1 }
        first ||= enrollments.first if config.name && enrollments.length == 1
        Dev::RunnerFamily.new(base: base, dir: first ? first.dir : setup.resolve_dir)
      end

      # The family's slots: by slot, the dirs enrolled under its name (one
      # is the steady state), and GitHub's record of each by name (absent
      # when GitHub has lost it). One enrollment under another name with
      # `--name` is a rename: it is slot 1, looked up under its new name —
      # the registry's answer says whether GitHub already knows the new
      # name (amend) or the re-enrollment renames.
      #
      # @param scope [String]
      # @param enrollments [Array<Dev::RunnerDiscovery::Enrollment>]
      # @param family [Dev::RunnerFamily]
      # @param config [Dev::RunnerSetupConfig]
      # @return [[Hash{Integer => Array<Enrollment>}, Hash{String => Runner}]]
      sig do
        params(
          scope: String,
          enrollments: T::Array[Dev::RunnerDiscovery::Enrollment],
          family: Dev::RunnerFamily,
          config: RunnerSetupConfig,
        ).returns([SlotMap, T::Hash[String, Dev::RunnerRegistry::Runner]])
      end
      def family_members(scope, enrollments, family, config)
        by_slot = T.let({}, SlotMap)
        enrollments.each do |enrollment|
          slot = family.slot_of(enrollment.name)
          (by_slot[slot] ||= []) << enrollment if slot
        end
        renamed = config.name && by_slot.empty? && enrollments.length == 1
        by_slot = { 1 => enrollments } if renamed

        runners = {}
        by_slot.values.flatten.each do |member|
          runner = @registry.find(scope: scope, name: renamed ? T.must(config.name) : member.name)
          runners[member.name] = runner if runner
        end
        [by_slot, runners]
      end

      # Whether what is on disk is not what is serving GitHub: two dirs
      # enrolled under one slot's name (one name, one registration — the
      # rest are `--replace` leftovers), an enrollment at the scope
      # outside the family (another host's name, or this one's before a
      # rename nobody asked for), a slot GitHub lists offline (nothing
      # runs it), or — under the host rule — an enrollment running as
      # someone other than the runner user. A slot GitHub has lost is not
      # this case: the re-enrollment path reuses its dir.
      #
      # @param enrollments [Array<Dev::RunnerDiscovery::Enrollment>] every one at the scope
      # @param by_slot [Hash{Integer => Array<Enrollment>}] the family's
      # @param runners [Hash{String => Dev::RunnerRegistry::Runner}] GitHub's record per member
      # @param runner_user [Dev::RunnerUser, nil] the host rule's user
      # @return [Boolean]
      sig do
        params(
          enrollments: T::Array[Dev::RunnerDiscovery::Enrollment],
          by_slot: SlotMap,
          runners: T::Hash[String, Dev::RunnerRegistry::Runner],
          runner_user: T.nilable(Dev::RunnerUser),
        ).returns(T::Boolean)
      end
      def superseded?(enrollments, by_slot, runners, runner_user)
        !duplicated(by_slot).empty? || !strangers(enrollments, by_slot).empty? ||
          runners.values.any? { |runner| !runner.online? } || !drifted(enrollments, runner_user).empty?
      end

      # The slots more than one dir is enrolled under.
      #
      # @param by_slot [Hash{Integer => Array<Enrollment>}]
      # @return [Array<Array<Enrollment>>]
      sig { params(by_slot: SlotMap).returns(T::Array[T::Array[Dev::RunnerDiscovery::Enrollment]]) }
      def duplicated(by_slot)
        by_slot.values.select { |dirs| dirs.length > 1 }
      end

      # The enrollments at the scope outside the family.
      #
      # @param enrollments [Array<Enrollment>]
      # @param by_slot [Hash{Integer => Array<Enrollment>}]
      # @return [Array<Enrollment>]
      sig { params(enrollments: T::Array[Dev::RunnerDiscovery::Enrollment], by_slot: SlotMap).returns(T::Array[Dev::RunnerDiscovery::Enrollment]) }
      def strangers(enrollments, by_slot)
        enrollments - by_slot.values.flatten
      end

      # The enrollments owned by someone other than the runner user; none
      # without a runner user.
      #
      # @param enrollments [Array<Dev::RunnerDiscovery::Enrollment>]
      # @param runner_user [Dev::RunnerUser, nil]
      # @return [Array<Dev::RunnerDiscovery::Enrollment>]
      sig do
        params(enrollments: T::Array[Dev::RunnerDiscovery::Enrollment], runner_user: T.nilable(Dev::RunnerUser))
          .returns(T::Array[Dev::RunnerDiscovery::Enrollment])
      end
      def drifted(enrollments, runner_user)
        return [] unless runner_user

        enrollments.reject { |enrollment| enrollment.owner == runner_user.name }
      end

      # List the superseded enrollments, ask, and unregister them all —
      # or, declined, raise with the by-hand remedy having changed nothing.
      #
      # @param scope [String]
      # @param enrollments [Array<Dev::RunnerDiscovery::Enrollment>] every one at the scope
      # @param by_slot [Hash{Integer => Array<Enrollment>}] the family's
      # @param runners [Hash{String => Dev::RunnerRegistry::Runner}]
      # @param runner_user [Dev::RunnerUser, nil] the host rule's user
      # @param yes [Boolean] `--yes`: answer the question without asking
      # @raise [SupersededEnrollmentsError] when the operator declines
      sig do
        params(
          scope: String,
          enrollments: T::Array[Dev::RunnerDiscovery::Enrollment],
          by_slot: SlotMap,
          runners: T::Hash[String, Dev::RunnerRegistry::Runner],
          runner_user: T.nilable(Dev::RunnerUser),
          yes: T::Boolean,
        ).void
      end
      def retire!(scope, enrollments, by_slot, runners, runner_user, yes:)
        signs = []
        duplicated(by_slot).each do |dirs|
          signs << "#{dirs.length} local enrollments named '#{T.must(dirs.first).name}'"
        end
        strangers(enrollments, by_slot).each do |enrollment|
          signs << "an enrollment named '#{enrollment.name}' outside this host's family"
        end
        runners.each do |name, runner|
          signs << "GitHub lists '#{name}' offline" unless runner.online?
        end
        drifted(enrollments, runner_user).each do |enrollment|
          signs << "an enrollment that runs as #{enrollment.owner}, not #{T.must(runner_user).name}"
        end
        @out.puts ">>> #{scope} has #{signs.join(" and ")} — the enrollment on disk is not what should be serving GitHub:"
        enrollments.each do |enrollment|
          @out.puts "    #{enrollment.display_dir} (#{enrollment.service_installed ? "service installed" : "no service"})"
        end

        unless yes || @confirmer.confirm?("Unregister these and enroll fresh?")
          remedy = enrollments.map { |enrollment| "  dev runner unregister #{enrollment.display_dir}" }.join("\n")
          raise SupersededEnrollmentsError,
            "nothing changed. Unregister them yourself, then re-run register:\n#{remedy}"
        end

        enrollments.each { |enrollment| @teardown.teardown!(enrollment) }
      end

      # `--slots N` under what is enrolled: list the slots past N, ask, and
      # unregister them — or, declined, raise having changed nothing.
      #
      # @param scope [String]
      # @param surplus [Array<Dev::RunnerDiscovery::Enrollment>] the slots past the asked count
      # @param yes [Boolean]
      # @raise [SurplusSlotsError] when the operator declines
      sig { params(scope: String, surplus: T::Array[Dev::RunnerDiscovery::Enrollment], yes: T::Boolean).void }
      def retire_surplus!(scope, surplus, yes:)
        return if surplus.empty?

        @out.puts ">>> #{scope} has #{surplus.length} more slot#{"s" if surplus.length > 1} than asked for:"
        surplus.each { |enrollment| @out.puts "    #{enrollment.name} (#{enrollment.display_dir})" }
        unless yes || @confirmer.confirm?("Unregister #{surplus.length == 1 ? "it" : "them"}?")
          remedy = surplus.map { |enrollment| "  dev runner unregister #{enrollment.display_dir}" }.join("\n")
          raise SurplusSlotsError, "nothing changed. Unregister them yourself, or re-run with the slots you have:\n#{remedy}"
        end

        surplus.each { |enrollment| @teardown.teardown!(enrollment) }
      end

      # The amend path: the discovered enrollment still exists on GitHub
      # and is online, so converge its custom labels in place — the
      # service, name, and dir all stay put.
      #
      # @param scope [String]
      # @param enrollment [Dev::RunnerDiscovery::Enrollment]
      # @param runner [Dev::RunnerRegistry::Runner] GitHub's record of it
      # @param config [Dev::RunnerSetupConfig]
      sig do
        params(
          scope: String,
          enrollment: Dev::RunnerDiscovery::Enrollment,
          runner: Dev::RunnerRegistry::Runner,
          config: RunnerSetupConfig,
        ).void
      end
      def amend_enrollment(scope, enrollment, runner, config)
        name = config.name || enrollment.name
        desired = config.labels.split(",")
        if runner.custom_labels.sort == desired.sort
          @out.puts ">>> Runner '#{name}' already serves #{scope} with labels #{config.labels} — nothing to amend."
        else
          @out.puts ">>> Amending labels of '#{name}' at #{scope}: " \
                    "#{runner.custom_labels.join(",")} -> #{config.labels} ..."
          @registry.amend!(scope: scope, runner_id: runner.id, labels: desired)
        end
      end

      # The advertised labels, by precedence: --labels (explicit set),
      # --ai-flow (the full vocabulary), else the derived repo label — the
      # name of the repo being enrolled (`--repo`, else the checkout's),
      # lowercased. Org scope has nothing to derive from, so bare --org is a
      # usage error; so is bare register outside a project, since the
      # checkout is also what sizes the engine.
      #
      # @param args [Array<String>]
      # @param context [Dev::ExecutionContext]
      # @param org [Boolean]
      # @return [String] comma-separated labels (config.sh shape)
      # @raise [ArgumentError] on an underivable or contradictory request
      # @raise [Dev::EnrolledRunner::MalformedRepoError] when the repo (`--repo`) is not an owner/repo
      # @raise [Dev::RunnerSetup::Error] when gh cannot resolve the checkout
      sig { params(args: Cli::ParsedArgs, context: ExecutionContext, org: T::Boolean).returns(String) }
      def resolve_labels(args, context, org)
        explicit = args.value(LABELS_FLAG)
        ai_flow = args.flag?(AI_FLOW_FLAG)
        if explicit && ai_flow
          raise ArgumentError,
            "--ai-flow enrolls the full ai-flow set (#{LabelContracts::AI_FLOW_LABELS.join(",")}); " \
              "pass --labels alone for a custom set"
        end
        return explicit if explicit
        return LabelContracts::AI_FLOW_LABELS.join(",") if ai_flow

        if org
          raise ArgumentError,
            "an org runner's role is not derivable — pass --ai-flow (the agent host) or --labels"
        end

        if context.project.nil?
          raise ArgumentError,
            "the repo label derives from the enclosing checkout (which also sizes the engine) — " \
              "run inside one or pass --labels"
        end
        # The one derivation (EnrolledRunner): what this enrolls is what
        # the remote dispatch's lookup asks GitHub for.
        Dev::EnrolledRunner.for(@repo_resolver.call(args.value(REPO_FLAG))).label
      end
    end
  end
end
