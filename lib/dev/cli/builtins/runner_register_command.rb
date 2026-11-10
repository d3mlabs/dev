# typed: strict
# frozen_string_literal: true

require "dev/agent_bootstrap"
require "dev/agent_bootstrap/darwin"
require "dev/cli/command"
require "dev/data_root"
require "dev/deps/lockfile"
require "dev/engine_provisioner"
require "dev/enrolled_runner"
require "dev/host_reach"
require "dev/label_contracts"
require "dev/linux_data_root_provisioner"
require "dev/operator_access"
require "dev/cli/project_manifest"
require "dev/runner_discovery"
require "dev/runner_slots"
require "dev/runner_group_contract"
require "dev/runner_groups"
require "dev/runner_registry"
require "dev/runner_setup"
require "dev/runner_setup_config"
require "dev/runner_teardown"
require "dev/runner_user"
require "dev/wsl_conf"
require "dev/wsl_keepalive_task"
require "dev/wsl_runner_host"

module Dev
  module Cli
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
      # N` enrolls N **slots** (Dev::RunnerSlots) — `<name>`, `<name>-2` ..
      # `<name>-N`, the name being the hostname by default, each its own
      # dir, `_work` and service, every one carrying the same labels. Slot
      # 1 is exactly the enrollment register has always made, so a host from
      # before slots has one; re-running without `--slots` keeps the count
      # it finds, a smaller `--slots` retires the surplus (asked first), a
      # larger one adds. Which repos may use an org host's slots is the runner
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
      # Inside a WSL2 distro the host has one more contract (dev#261,
      # WslRunnerHost): the distro is dormant until a client session holds
      # it, and WSL stops it ~20 s after the last one ends — runner services
      # included — so register converges the Windows side a WSL runner needs
      # before enrolling: the logon keepalive task that boots the distro and
      # holds a session, systemd in `/etc/wsl.conf`, and `.wslconfig`'s size
      # (asserted here for every enrollment, not assumed from a `dev up`).
      # It needs the session's interop and refuses without it.
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

        # The host's enrollments at a scope by slot: the dirs enrolled under
        # each slot's name (one is the steady state; more are `--replace`
        # leftovers).
        SlotMap = T.type_alias { T::Hash[Integer, T::Array[Dev::RunnerDiscovery::Enrollment]] }

        # Builds the RunnerSetup for the resolved config and flags, speaking
        # on the context's Ui; injected so tests can observe the wiring
        # without touching gh or the host.
        RunnerSetupFactory = T.type_alias do
          T.proc.params(
            config: RunnerSetupConfig,
            repo: T.nilable(String),
            org: T::Boolean,
            runner_user: T.nilable(Dev::RunnerUser),
            ui: Ui,
          ).returns(Dev::RunnerSetup)
        end

        # The host rule: the runner user for this host (nil off Linux), given
        # what `--as` named; injected for tests.
        RunnerUserFactory = T.type_alias { T.proc.params(name: T.nilable(String)).returns(T.nilable(Dev::RunnerUser)) }

        # The checkout's lock, as the reach check reads it; injected for tests.
        PinsReader = T.type_alias { T.proc.params(root: Pathname).returns(T::Array[Dev::Deps::Dependency]) }

        # The reach check for an identity; injected for tests.
        ReachFactory = T.type_alias { T.proc.params(identity: Dev::RunnerUser).returns(Dev::HostReach) }

        # Resolves the advertised labels' contracts for the agent user and
        # the host rule's runner user (nil on a Mac); injected for tests.
        ContractsFactory = T.type_alias do
          T.proc.params(
            labels: String,
            agent_user: T.nilable(String),
            runner_user: T.nilable(String),
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
            engine_provisioner: Dev::EngineProvisioner,
            runner_user_factory: RunnerUserFactory,
            data_root_provisioner: T.nilable(Dev::LinuxDataRootProvisioner),
            wsl_runner_host: T.nilable(Dev::WslRunnerHost),
            pins_reader: PinsReader,
            reach_factory: ReachFactory,
            groups: T.nilable(Dev::RunnerGroups),
            refresher: Dev::OperatorAccess::Refresher,
          ).void
        end
        def initialize(
          runner_setup_factory: ->(config, repo, org, runner_user, ui) {
            Dev::RunnerSetup.new(config:, repo:, org:, as_user: runner_user&.name, home: runner_user&.home, path: runner_user&.path, ui:)
          },
          contracts_factory: ->(labels, agent_user, runner_user) {
            Dev::LabelContracts.for(labels, agent_user: agent_user, runner_user: runner_user)
          },
          repo_resolver: ->(override) { override || Dev::RunnerSetup.current_repo },
          discovery: Dev::RunnerDiscovery.new,
          # The GitHub boundary (#find/#amend!); T.untyped so tests fake it.
          registry: Dev::RunnerRegistry.new,
          # `dev runner unregister`'s implementation, for superseded enrollments.
          teardown: Dev::RunnerTeardown.new(discovery: discovery),
          # `dev up`'s engine step, run here for the checked-out repo's hint.
          engine_provisioner: Dev::EngineProvisioner.new,
          # The host rule (Linux: a runner user; elsewhere nil).
          runner_user_factory: ->(name) { Dev::RunnerUser.for_host(name: name) },
          # The shared data root the runner user joins; nil off Linux.
          data_root_provisioner: Dev::LinuxDataRootProvisioner.for_host,
          # The Windows side a WSL runner needs (dev#261); nil off WSL.
          wsl_runner_host: Dev::WslRunnerHost.for_host,
          pins_reader: ->(root) { Dev::Deps::Lockfile.new(dir: root).read },
          reach_factory: ->(identity) { Dev::HostReach.new(identity: identity) },
          # The org's runner groups, converged over the same registry.
          groups: nil,
          # How the operator's login is widened when the pre-flight offers it.
          refresher: Dev::OperatorAccess::DEFAULT_REFRESHER
        )
          super()
          @groups = T.let(groups || Dev::RunnerGroups.new(registry: registry), Dev::RunnerGroups)
          # The operator's own preconditions, probed first (dev#493).
          @operator_access = T.let(
            Dev::OperatorAccess.new(registry: registry, refresher: refresher),
            Dev::OperatorAccess,
          )
          @runner_setup_factory = runner_setup_factory
          @contracts_factory = contracts_factory
          @repo_resolver = repo_resolver
          @discovery = discovery
          @registry = registry
          @teardown = teardown
          @engine_provisioner = engine_provisioner
          @runner_user_factory = runner_user_factory
          @data_root_provisioner = data_root_provisioner
          @wsl_runner_host = wsl_runner_host
          @pins_reader = pins_reader
          @reach_factory = reach_factory
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
            or --repo's — is admitted to it. Agent labels sit in the '#{LabelContracts::AI_FLOW_GROUP.name}' group,
            which dev owns: created when missing, pinned to ai-flow's workflows (plans#5
            H3), healed when the console drifted — nothing to remember; its selection is
            each repo's build concurrency on the host, so admission is deliberate.
            #{LabelContracts::ORCHESTRATOR_LABEL} sits in its own '#{LabelContracts::ORCHESTRATOR_GROUP.name}' group, same pin, open to
            every repo (nothing to gate; nothing admitted); mixing the two in --labels is
            refused — one enrollment, one group. --group names a
            human's group for other pools. A public repo may only use a pinned group;
            register refuses otherwise. A repo-scoped enrollment is that repo's alone
            (cellbound-3d's editor); its concurrency is its own --slots — and when the repo
            may also use the org's slots for the same labels, register asks whether this
            runner should be its only one, taking it out of the group on yes.

            Two kinds of ai-flow host. An agent host (--ai-flow, or --labels over
            #{LabelContracts::AI_FLOW_AGENT_LABELS.join(" ")}) runs the agent: one slot is one agent
            run, sized for it, and the agent host bootstrap converges. An orchestrator
            (--labels #{LabelContracts::ORCHESTRATOR_LABEL}) runs `/build --split`'s poll loop — API calls and
            sleep for a plan's whole critical path — so it is for an always-on thin
            box: nothing converges beyond the runner host rule, slots are cheap (a
            listener each), and --ai-flow never includes it, so an agent host does not
            lose a build slot to it. A host may carry both families at different
            scopes (the box: its repo-scoped build runner, plus the org's
            orchestrators); each scope's enrollments are discovered and sized on their
            own. If the orchestrate job sits at "Waiting for a runner" GitHub says no
            more than its requested labels: the org's Runners page must list an Idle
            runner carrying #{LabelContracts::ORCHESTRATOR_LABEL} in the '#{LabelContracts::ORCHESTRATOR_GROUP.name}' group.

            Three identities meet in a registration:
              you (gh auth)         mints the registration token — repo admin, or admin:org with --org
              the runner user       owns the enrollment: the dir, config.sh's record, and the gh login
                                    every job on this host fetches private dependencies with
              root (sudo)           installs the service unit
            and a job writes to its own repo with its GITHUB_TOKEN, never with a host login.
            Your login is probed first — the call the registration will make (the org's
            runner groups with --org; the repo's runners otherwise) — before sudo or brew
            run: refused, register names what it needs that for and the classic-scope
            fix, offers `gh auth refresh -h github.com -s admin:org` (or -s repo) at a
            terminal, and stops otherwise.

            On Linux the runner user is `#{Dev::RunnerUser::DEFAULT_NAME}` by rule (--as renames it): created if absent, in
            docker and #{DataRoot::GROUP}, no password, no sudo; its commands and every job run on the
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

            Inside a WSL2 distro, register also converges what a runner there needs to
            survive a reboot (dev#261): WSL stops a distro ~20 s after its last client
            session ends, and the runner's systemd service is not a session, so a Task
            Scheduler task at log on (`Start-WSL-<distro>-Runner`) holds one open —
            `#{WslKeepaliveTask::EXECUTE} --headless wsl.exe -d <distro> -u root -- sleep infinity`, no time
            limit, one instance; systemd is enabled in #{WslConf::PATH}; and .wslconfig is
            sized for the checkout's hint (the `dev up` step, asserted here). This needs
            the session's interop (powershell.exe), so run register from a shell opened in
            the distro on the Windows desktop, not over ssh; replacing a task a bootstrap
            script registered as an administrator takes one UAC prompt. A restart dev asks
            for is yours (`wsl --shutdown`, then `Start-ScheduledTask` or a new logon).

            An agent host is a Mac or a Linux dev host (plans#59). Agent labels converge the
            same facts on both: the non-admin agent user (`#{AgentBootstrap::DEFAULT_AGENT_USER}`, --agent-user
            renames it) in the data root's `#{DataRoot::GROUP}` group beside the runner user; the one-way
            sudoers edge from the runner user to the agent (NOPASSWD, SETENV — the operator on a
            Mac, `#{Dev::RunnerUser::DEFAULT_NAME}` on Linux) with the brew edge onto the prefix owner's brew; the tap
            trusted as the agent; the `_work` tree group-writable; and the service env naming
            the agent user, the group and the slot (#{AgentBootstrap::AGENT_USER_ENV}, #{AgentBootstrap::AGENT_GROUP_ENV},
            #{AgentBootstrap::RUNNER_SLOT_ENV}) under a 002 umask — a LaunchAgent plist on a Mac, a systemd unit
            drop-in on Linux. A Mac provisions the shared root (#{DataRoot::SHARED_ROOT}) and
            gives the agent its own colima when the checkout pins an image; a Linux host
            joins the agent to the root `dev up` made and has no agent engine — an
            image-built repo's agent runs inside the project's container (plans#61), so
            agent labels for such a repo are refused there until that lands. A Mac
            bootstrapped before the one group name re-groups its root and `_work` trees from
            `#{AgentBootstrap::Darwin::LEGACY_GROUP}` to `#{DataRoot::GROUP}` on its next register.

            Examples:
              dev runner register                      # repo scope; label = the repo name
              dev runner register --labels ue-engine   # repo scope, custom roles
              dev runner register --org --ai-flow      # org agent host, the full ai-flow set
              dev runner register --org --labels ai-build
              dev runner register --org --ai-flow --slots 3    # three jobs at once; this repo may use them
              dev runner register --org --labels #{LabelContracts::ORCHESTRATOR_LABEL} --slots 4   # the orchestrator pool, on an always-on thin box
              dev runner register --ai-flow                    # this repo's own agent runner; asks to leave the org's pool
              dev runner register --org --labels ue-engine --group ue-hosted   # a human's pool
          DESC
        end

        sig { override.returns(Command::Category) }
        def category
          Command::Category::Environment
        end

        sig { override.returns(T::Array[Cli::Flag]) }
        def flags
          [
            Cli::Flag.new(ORG_FLAG, desc: "enroll at the org scope (needs admin:org); labels are required"),
            Cli::Flag.new(LABELS_FLAG, takes_value: true, desc: "comma-separated labels; default: the repo's name"),
            Cli::Flag.new(AI_FLOW_FLAG, desc: "the agent host's ai-flow label set (#{LabelContracts::AI_FLOW_AGENT_LABELS.join(",")}); the orchestrator pool is --labels #{LabelContracts::ORCHESTRATOR_LABEL}"),
            Cli::Flag.new(SLOTS_FLAG, takes_value: true, desc: "how many jobs this host runs at once at this scope: N runners, <name>, <name>-2 .. <name>-N; default: what is enrolled, else 1"),
            Cli::Flag.new(GROUP_FLAG, takes_value: true, desc: "--org: the runner group the slots join (made once in the org's settings); agent labels imply '#{LabelContracts::AI_FLOW_GROUP.name}', #{LabelContracts::ORCHESTRATOR_LABEL} implies '#{LabelContracts::ORCHESTRATOR_GROUP.name}'; default: #{DEFAULT_GROUP}"),
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
          # The one repo derivation (`--repo`, else the checkout's): the
          # label, the operator pre-flight and the group's access all read
          # it — after the usage checks, so a bare --org is told what it is
          # missing rather than what gh could not resolve.
          resolve_repo = memoized { @repo_resolver.call(args.value(REPO_FLAG)) }
          labels = resolve_labels(args, context, org, resolve_repo)
          repo = resolve_repo.call
          slots = resolve_slots(args)
          contract = resolve_group(args, labels, org)
          config = RunnerSetupConfig.new(
            labels: labels,
            dir: args.value(DIR_FLAG),
            name: args.value(NAME_FLAG),
            group: contract&.name,
          )

          # The operator's login first, before sudo, brew or the engine: can
          # it do what this registration asks of it (mint tokens; with --org,
          # read and converge runner groups)? Refused, this is where it stops.
          @operator_access.check!(scope: org ? T.must(repo.split("/").first) : repo, org: org, ui: context.ui)

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

          # The WSL runner host (dev#261): the logon keepalive, systemd and
          # `.wslconfig` a runner in a WSL2 distro needs to survive a reboot.
          # After the runner user (its wsl.conf write rides the same sudo
          # session), before any contract or enrollment: a host that goes
          # down at the next reboot is not one to enroll on.
          @wsl_runner_host&.converge!(resources: engine)

          # The agent host contract spawns the agent from the enrolling
          # user's service: the runner user on Linux, the operator on a Mac.
          contracts = @contracts_factory.call(labels, args.value(AGENT_USER_FLAG), runner_user&.name)
          contracts.each do |contract|
            contract.converge!(
              container: container,
              cpus: engine&.cpus,
              memory_gib: engine&.memory_gib,
              disk_gib: engine&.disk_gib,
            )
          end

          setup = @runner_setup_factory.call(config, args.value(REPO_FLAG), org, runner_user, context.ui)
          scope = setup.resolve_scope
          yes = args.flag?(YES_FLAG)
          # The org-side contract first: the group the slots will join must
          # exist, with its access, before config.sh names it.
          group = contract && @groups.converge!(contract, org: scope, ui: context.ui)
          # --dir is the operator picking the dir: no discovery, no detection.
          # The runner user's home is where the rule puts enrollments; the
          # operator's is where the ones from before it are.
          discovery = runner_user ? @discovery.also_under(runner_user.home) : @discovery
          enrollments = config.dir ? [] : discovery.enrollments_for(scope)
          naming = resolve_naming(enrollments, config, setup, slots)
          by_slot, runners = enrolled_slots(scope, enrollments, naming, config)

          if superseded?(enrollments, by_slot, runners, runner_user)
            retire!(scope, enrollments, by_slot, runners, runner_user, yes: yes, ui: context.ui)
            by_slot = {}
            runners = {}
          end

          # How many slots: what --slots says, else what is enrolled (the
          # highest slot — a gap is re-filled), else one.
          count = slots || by_slot.keys.max || 1
          retire_surplus!(scope, by_slot.select { |slot, _dirs| slot > count }.values.flatten, yes: yes, ui: context.ui)

          (1..count).each do |slot|
            enrollment = by_slot[slot]&.first
            runner = enrollment && runners[enrollment.name]
            if enrollment && runner
              amend_enrollment(scope, enrollment, runner, config, ui: context.ui)
              @groups.place!(group, runner, org: scope, ui: context.ui) if group
              contracts.each { |contract| contract.after_enroll!(runner_dir: enrollment.dir, slot: slot) }
              next
            end

            slot_setup = setup
            if enrollment || slot > 1
              # GitHub has lost this enrollment (or --name renames it): the
              # re-enrollment reuses the discovered dir, never a second one.
              # A slot beyond the first is named and placed from slot 1.
              slot_config = RunnerSetupConfig.new(
                labels: labels,
                dir: enrollment&.dir || naming.slot_dir(slot),
                name: config.name || naming.slot_name(slot),
                group: config.group,
              )
              slot_setup = @runner_setup_factory.call(slot_config, args.value(REPO_FLAG), org, runner_user, context.ui)
            end
            slot_setup.run
            contracts.each { |contract| contract.after_enroll!(runner_dir: slot_setup.resolve_dir, slot: slot) }
          end

          if org
            converge_access!(scope, group, repo, ui: context.ui)
          else
            offer_exclusivity!(scope, labels, yes: yes, ui: context.ui)
          end
        end

        private

        # Who may use the slots (dev#470: a repo's concurrency on a host is
        # the runners it can see): the repo this registration is for — the
        # checkout's, or `--repo`'s, the same derivation as the org and the
        # label — is admitted to their group. Slots naming no group
        # sit in GitHub's Default, so that is the group converged for them.
        #
        # @param scope [String] the org
        # @param group [Dev::RunnerRegistry::Group, nil] the contract's group, when one was obliged
        # @param repo [String] the repo this registration is for
        # @param ui [Ui]
        sig { params(scope: String, group: T.nilable(Dev::RunnerRegistry::Group), repo: String, ui: Ui).void }
        def converge_access!(scope, group, repo, ui:)
          access = group || @registry.group(org: scope, name: DEFAULT_GROUP)
          return if access.nil?

          @groups.admit!(access, repo, org: scope, ui: ui)
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
        # @param ui [Ui] asks; no terminal is a no
        sig { params(scope: String, labels: String, yes: T::Boolean, ui: Ui).void }
        def offer_exclusivity!(scope, labels, yes:, ui:)
          contract = LabelContracts.group_for(labels)
          return unless contract

          org = T.must(scope.split("/").first)
          group = @registry.group(org: org, name: contract.name)
          return unless group&.selected?
          return unless @registry.group_repositories(org: org, group_id: group.id).any? { |selected| selected.full_name.casecmp?(scope) }

          ui.note("#{scope} may also use the org's '#{group.name}' runners for these labels — its jobs would land on either")
          unless yes || ui.confirm("Make this host's runner its only one?")
            ui.note("{{v}} Left as is: #{scope} keeps using the org's '#{group.name}' runners too")
            return
          end

          @groups.exclude!(group, scope, org: org, ui: ui)
        rescue RunnerRegistry::QueryError => e
          ui.note("{{?}} Could not read #{org}'s runner groups (#{e.message}) — whether #{scope} also uses the org's runners is unchecked")
        end

        # `--slots N`: how many slots, a positive integer; nil leaves it
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
              "these labels sit in the '#{obliged.name}' runner group (pinned to ai-flow's workflows) — drop #{GROUP_FLAG} #{named}"
          end

          obliged || (named && RunnerGroupContract.new(name: named))
        end

        # How this host's slots at the scope are named: slot 1 by `--name`,
        # else by the one base the discovered enrollments share, else the
        # hostname. Slot 1's dir is its enrollment's when one exists, else
        # the setup's default (`--dir` included).
        #
        # @param enrollments [Array<Dev::RunnerDiscovery::Enrollment>]
        # @param config [Dev::RunnerSetupConfig]
        # @param setup [Dev::RunnerSetup]
        # @param slots [Integer, nil]
        # @return [Dev::RunnerSlots]
        sig do
          params(
            enrollments: T::Array[Dev::RunnerDiscovery::Enrollment],
            config: RunnerSetupConfig,
            setup: Dev::RunnerSetup,
            slots: T.nilable(Integer),
          ).returns(Dev::RunnerSlots)
        end
        def resolve_naming(enrollments, config, setup, slots)
          bases = enrollments.map { |enrollment| Dev::RunnerSlots.base_of(enrollment.name) }.uniq
          # The hostname is asked for only when a second slot has to be
          # named from it: a lone fresh enrollment keeps the setup's own
          # derivation, as it always has.
          base = config.name || (bases.length == 1 ? T.must(bases.first) : nil) || (slots.to_i > 1 ? setup.resolve_name : "")
          provisional = Dev::RunnerSlots.new(base: base, dir: setup.resolve_dir)
          first = enrollments.find { |enrollment| provisional.slot_of(enrollment.name) == 1 }
          first ||= enrollments.first if config.name && enrollments.length == 1
          Dev::RunnerSlots.new(base: base, dir: first ? first.dir : setup.resolve_dir)
        end

        # The enrolled slots: by slot, the dirs enrolled under its name (one
        # is the steady state), and GitHub's record of each by name (absent
        # when GitHub has lost it). One enrollment under another name with
        # `--name` is a rename: it is slot 1, looked up under its new name —
        # the registry's answer says whether GitHub already knows the new
        # name (amend) or the re-enrollment renames.
        #
        # @param scope [String]
        # @param enrollments [Array<Dev::RunnerDiscovery::Enrollment>]
        # @param naming [Dev::RunnerSlots]
        # @param config [Dev::RunnerSetupConfig]
        # @return [[Hash{Integer => Array<Enrollment>}, Hash{String => Runner}]]
        sig do
          params(
            scope: String,
            enrollments: T::Array[Dev::RunnerDiscovery::Enrollment],
            naming: Dev::RunnerSlots,
            config: RunnerSetupConfig,
          ).returns([SlotMap, T::Hash[String, Dev::RunnerRegistry::Runner]])
        end
        def enrolled_slots(scope, enrollments, naming, config)
          by_slot = T.let({}, SlotMap)
          enrollments.each do |enrollment|
            slot = naming.slot_of(enrollment.name)
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
        # outside this host's slots (another host's name, or this one's before a
        # rename nobody asked for), a slot GitHub lists offline (nothing
        # runs it), or — under the host rule — an enrollment running as
        # someone other than the runner user. A slot GitHub has lost is not
        # this case: the re-enrollment path reuses its dir.
        #
        # @param enrollments [Array<Dev::RunnerDiscovery::Enrollment>] every one at the scope
        # @param by_slot [Hash{Integer => Array<Enrollment>}] this host's slots
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

        # The enrollments at the scope that are none of this host's slots.
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
        # @param by_slot [Hash{Integer => Array<Enrollment>}] this host's slots
        # @param runners [Hash{String => Dev::RunnerRegistry::Runner}]
        # @param runner_user [Dev::RunnerUser, nil] the host rule's user
        # @param yes [Boolean] `--yes`: answer the question without asking
        # @param ui [Ui] asks; no terminal is a no
        # @raise [SupersededEnrollmentsError] when the operator declines
        sig do
          params(
            scope: String,
            enrollments: T::Array[Dev::RunnerDiscovery::Enrollment],
            by_slot: SlotMap,
            runners: T::Hash[String, Dev::RunnerRegistry::Runner],
            runner_user: T.nilable(Dev::RunnerUser),
            yes: T::Boolean,
            ui: Ui,
          ).void
        end
        def retire!(scope, enrollments, by_slot, runners, runner_user, yes:, ui:)
          signs = []
          duplicated(by_slot).each do |dirs|
            signs << "#{dirs.length} local enrollments named '#{T.must(dirs.first).name}'"
          end
          strangers(enrollments, by_slot).each do |enrollment|
            signs << "an enrollment named '#{enrollment.name}' that is none of this host's slots"
          end
          runners.each do |name, runner|
            signs << "GitHub lists '#{name}' offline" unless runner.online?
          end
          drifted(enrollments, runner_user).each do |enrollment|
            signs << "an enrollment that runs as #{enrollment.owner}, not #{T.must(runner_user).name}"
          end
          ui.note("{{x}} #{scope} has #{signs.join(" and ")} — the enrollment on disk is not what should be serving GitHub:")
          enrollments.each do |enrollment|
            ui.note("    #{enrollment.display_dir} (#{enrollment.service_installed ? "service installed" : "no service"})")
          end

          unless yes || ui.confirm("Unregister these and enroll fresh?")
            remedy = enrollments.map { |enrollment| "  dev runner unregister #{enrollment.display_dir}" }.join("\n")
            raise SupersededEnrollmentsError,
              "nothing changed. Unregister them yourself, then re-run register:\n#{remedy}"
          end

          enrollments.each { |enrollment| @teardown.teardown!(enrollment, ui: ui) }
        end

        # `--slots N` under what is enrolled: list the slots past N, ask, and
        # unregister them — or, declined, raise having changed nothing.
        #
        # @param scope [String]
        # @param surplus [Array<Dev::RunnerDiscovery::Enrollment>] the slots past the asked count
        # @param yes [Boolean]
        # @param ui [Ui] asks; no terminal is a no
        # @raise [SurplusSlotsError] when the operator declines
        sig { params(scope: String, surplus: T::Array[Dev::RunnerDiscovery::Enrollment], yes: T::Boolean, ui: Ui).void }
        def retire_surplus!(scope, surplus, yes:, ui:)
          return if surplus.empty?

          ui.note("#{scope} has #{surplus.length} more slot#{"s" if surplus.length > 1} than asked for:")
          surplus.each { |enrollment| ui.note("    #{enrollment.name} (#{enrollment.display_dir})") }
          unless yes || ui.confirm("Unregister #{surplus.length == 1 ? "it" : "them"}?")
            remedy = surplus.map { |enrollment| "  dev runner unregister #{enrollment.display_dir}" }.join("\n")
            raise SurplusSlotsError, "nothing changed. Unregister them yourself, or re-run with the slots you have:\n#{remedy}"
          end

          surplus.each { |enrollment| @teardown.teardown!(enrollment, ui: ui) }
        end

        # The amend path: the discovered enrollment still exists on GitHub
        # and is online, so converge its custom labels in place — the
        # service, name, and dir all stay put.
        #
        # @param scope [String]
        # @param enrollment [Dev::RunnerDiscovery::Enrollment]
        # @param runner [Dev::RunnerRegistry::Runner] GitHub's record of it
        # @param config [Dev::RunnerSetupConfig]
        # @param ui [Ui] the amend is a spin (captured gh); nothing to do, a note
        sig do
          params(
            scope: String,
            enrollment: Dev::RunnerDiscovery::Enrollment,
            runner: Dev::RunnerRegistry::Runner,
            config: RunnerSetupConfig,
            ui: Ui,
          ).void
        end
        def amend_enrollment(scope, enrollment, runner, config, ui:)
          name = config.name || enrollment.name
          desired = config.labels.split(",")
          if runner.custom_labels.sort == desired.sort
            ui.note("{{v}} Runner '#{name}' already serves #{scope} with labels #{config.labels} — nothing to amend")
          else
            ui.spin("Amending labels of '#{name}' at #{scope}: #{runner.custom_labels.join(",")} → #{config.labels}") do
              @registry.amend!(scope: scope, runner_id: runner.id, labels: desired)
            end
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
        # @param context [Dev::Cli::ExecutionContext]
        # @param org [Boolean]
        # @param resolve_repo [Proc] derives the repo this registration is for, asked only when the label derives from it
        # @return [String] comma-separated labels (config.sh shape)
        # @raise [ArgumentError] on an underivable or contradictory request
        # @raise [Dev::EnrolledRunner::MalformedRepoError] when the repo (`--repo`) is not an owner/repo
        # @raise [Dev::RunnerSetup::Error] when gh cannot resolve the checkout
        sig { params(args: Cli::ParsedArgs, context: ExecutionContext, org: T::Boolean, resolve_repo: T.proc.returns(String)).returns(String) }
        def resolve_labels(args, context, org, resolve_repo)
          explicit = args.value(LABELS_FLAG)
          ai_flow = args.flag?(AI_FLOW_FLAG)
          if explicit && ai_flow
            raise ArgumentError,
              "--ai-flow enrolls the agent host's ai-flow set (#{LabelContracts::AI_FLOW_AGENT_LABELS.join(",")}); " \
                "pass --labels alone for a custom set"
          end
          return explicit if explicit
          return LabelContracts::AI_FLOW_AGENT_LABELS.join(",") if ai_flow

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
          Dev::EnrolledRunner.for(resolve_repo.call).label
        end

        # A thunk that computes once and answers the same thereafter.
        #
        # @yieldreturn [String]
        # @return [Proc]
        sig { params(blk: T.proc.returns(String)).returns(T.proc.returns(String)) }
        def memoized(&blk)
          value = T.let(nil, T.nilable(String))
          -> { value ||= blk.call }
        end
      end
    end
  end
end
