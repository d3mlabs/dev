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
require "dev/reach"
require "dev/runner_role"
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
      # `dev runner register`: converge the host, then enroll it as a
      # self-hosted runner. A registration declares the role its slots play
      # (RunnerRole); labels, group, scope, name and dir derive from it.
      # `runner_roles:` in dev.yml declares a repo's own roles:
      #
      #   dev runner register                    # the repo's build host; label = the repo name
      #   dev runner register --labels ue-engine # a build host with custom capabilities
      #   dev runner register --role agent       # org agent host, the full ai-flow set (--ai-flow)
      #   dev runner register --role orchestrator --slots 4   # the thin pool
      #   dev runner register --role ue-farm     # a dev.yml role
      #   dev runner register --role agent --slots 3  # three jobs at once
      #
      # Three roles are builtin: `agent` (the ai-flow agent labels, the
      # pinned `ai-flow` group), `orchestrator` (`ai-orchestrator`, its own
      # pinned group) and `build-host` (the repo's label or `--labels`, no
      # group). A role with a pinned group is org-scoped, since only a group
      # carries the pin; a build host is its repo's unless `--org` makes a
      # `--labels` set an org pool. `--role x` undeclared, `--role x
      # --labels y`, and `--org` with a dev.yml role are refused. A build
      # host for a public repo is refused: any workflow could then run on
      # the host (Reach::ExposedError).
      #
      # A self-hosted runner runs one job at a time, so `--slots N` enrolls
      # N slots (`<name>`, `<name>-2` .. `<name>-N`), each its own dir,
      # `_work` and service, all carrying the same labels. Re-running
      # without `--slots` keeps the count it finds; a smaller `--slots`
      # retires the surplus (asked first), a larger one adds. A family is
      # `(scope, host, role)`; a host plays each role at most once per
      # scope, and register sizes, amends and retires only the family it
      # was asked for. Which repos may use an org host's slots is the
      # runner group the role names (or `--group`, a human's); the repo
      # this registration is for is admitted to it.
      #
      # register is idempotent. When the checkout's lock pins an image, it
      # first brings the engine up for the repo's resources hint, for the
      # invoking user. Then it converges every advertised label's contract,
      # looks for an existing enrollment at the target scope and amends its
      # labels in place on GitHub; only a scope nothing serves gets the full
      # enrollment (RunnerSetup).
      #
      # Before amending, register checks that the enrollment on disk is the
      # one serving GitHub. More than one local enrollment for the scope, or
      # GitHub listing the runner offline, means it is not; register lists
      # the enrollments and asks to unregister them all and enroll fresh.
      # `--yes` answers for it; "no" changes nothing and prints the `dev
      # runner unregister` commands.
      #
      # Register never steals a registration. Runner names are unique per
      # scope, and `config.sh --replace` would silently take over another
      # runner's record. So before any slot enrolls, every fresh slot's name
      # is looked up at the scope: a name nothing holds enrolls without
      # `--replace`; one held by this host's own registration (same family,
      # same `.runner` id) is re-enrolled with it; any other
      # holder refuses, naming its labels and status.
      #
      # On Linux the enrollment is the runner user's: register converges the
      # shared data root and the runner user (`runner`; `--as` renames it) in
      # one sudo session, and refuses while that user has no gh login. An
      # enrollment owned by anyone else is drift and takes the
      # retire-and-enroll-fresh path. With a checkout, the runner user's
      # reach over its lock is checked before enrolling (HostReach). macOS
      # has no runner user.
      #
      # Inside a WSL2 distro register also converges the Windows side a
      # runner needs (WslRunnerHost): the logon keepalive task, systemd in
      # `/etc/wsl.conf`, and `.wslconfig`'s size. It needs the session's
      # interop and refuses without it.
      #
      # Enrollment state is inspected, never recorded: the labels live on
      # GitHub, the scope in the runner dir's own `.runner` record.
      #
      # `--org` needs no project; bare register runs inside the checkout it
      # enrolls and makes that repo's enrolled runner (Dev::EnrolledRunner):
      # repo scope, the repo's GitHub name lowercased as label. That
      # enrollment is what the lifecycle verbs' remote dispatch targets.
      # `--dir`/`--name`/`--repo` override the enrollment identity;
      # `--agent-user` the ai-agent default run-as user.
      class RunnerRegisterCommand < BuiltinCommand
        extend T::Sig

        # The operator declined to unregister the superseded enrollments, so
        # register did not enroll: the message carries the by-hand remedy.
        # A RuntimeError so the CLI boundary prints it and exits 1.
        class SupersededEnrollmentsError < RuntimeError; end

        # The operator declined to unregister the slots past `--slots N`, so
        # register changed nothing: the message carries the by-hand remedy.
        class SurplusSlotsError < RuntimeError; end

        # A slot's name is registered at the scope by another family — not
        # this host's, this scope's and this group's own — so register did
        # not enroll rather than let `config.sh --replace` take it over
        # A RuntimeError so the CLI boundary prints it and exits 1.
        class RegistrationHeldError < RuntimeError; end

        ORG_FLAG = "--org"
        ROLE_FLAG = "--role"
        LABELS_FLAG = "--labels"
        AI_FLOW_FLAG = "--ai-flow"
        SLOTS_FLAG = "--slots"
        GROUP_FLAG = "--group"

        # Where config.sh puts a registration naming no group: GitHub's own
        # default runner group, present in every org.
        DEFAULT_GROUP = RunnerRole::DEFAULT_POOL
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
        RunnerUserFactory = T.type_alias { T.proc.params(name: T.nilable(String), ui: Ui).returns(T.nilable(Dev::RunnerUser)) }

        # The checkout's lock, as the reach check reads it; injected for tests.
        PinsReader = T.type_alias { T.proc.params(root: Pathname).returns(T::Array[Dev::Deps::Dependency]) }

        # The reach check for an identity; injected for tests.
        ReachFactory = T.type_alias { T.proc.params(identity: Dev::RunnerUser).returns(Dev::HostReach) }

        # Resolves the advertised labels' contracts for the agent user and
        # the host rule's runner user (nil on a Mac), speaking on the Ui;
        # injected for tests.
        ContractsFactory = T.type_alias do
          T.proc.params(
            labels: String,
            agent_user: T.nilable(String),
            runner_user: T.nilable(String),
            ui: Ui,
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
          contracts_factory: ->(labels, agent_user, runner_user, ui) {
            Dev::LabelContracts.for(labels, agent_user: agent_user, runner_user: runner_user, ui: ui)
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
          runner_user_factory: ->(name, ui) { Dev::RunnerUser.for_host(name: name, ui: ui) },
          # The shared data root the runner user joins; nil off Linux.
          data_root_provisioner: Dev::LinuxDataRootProvisioner.for_host,
          # The Windows side a WSL runner needs; nil off WSL.
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
          # The operator's own preconditions, probed first.
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
            Enroll this host as a self-hosted runner in a role (--role; --ai-flow, --labels), converging its contracts

            Converges (engine, label contracts), then enrolls — or amends an existing
            enrollment's labels in place. Re-running is the idempotent no-op and the
            drift repair.

            A registration declares the ROLE its slots play; labels, group, scope, name
            and directory derive from it. Builtin: #{RunnerRole::AGENT_NAME} (the ai-flow agent set
            #{LabelContracts::AI_FLOW_AGENT_LABELS.join(" ")}, the pinned '#{LabelContracts::AI_FLOW_GROUP.name}' group,
            the agent host bootstrap), #{RunnerRole::ORCHESTRATOR_NAME} (#{LabelContracts::ORCHESTRATOR_LABEL}, its open pinned group), and
            the build host (bare register: the repo's own label; --labels: custom
            capabilities; no group). --ai-flow is --role agent; --labels #{LabelContracts::ORCHESTRATOR_LABEL} is
            --role orchestrator. A role this repo's dev.yml declares under runner_roles:
            (`ue-farm: { labels: [ue, gpu] }`) enrolls with --role ue-farm — identity and
            labels only; --role x with no declaration, or with --labels, is refused.
            Scope follows the role: agent and orchestrator live at the org because only a
            group carries the workflow pin (plans#5 H3) — --org is implied; a build host is
            its repo's unless --org makes a custom --labels set an org pool; a dev.yml role
            is always its repo's. Names: <hostname>-<role>[-n] for agent, orchestrator and
            dev.yml roles (JPSFF-agent, JPSFF-agent-2, beside JPSFF-orchestrator…), the
            bare hostname for a build host; dirs actions-runner-<role>[-n]. A family
            already enrolled keeps the names it has. Which role an enrollment plays is
            read from GitHub's labels, or for one GitHub has lost from the pool its .runner
            record names — never from its name or dir. A build host for a PUBLIC repo is
            refused: any workflow against a public repo is plans#5 Gap 1 reopened.

            Concurrency is the runner layer's: a self-hosted runner runs one job at a
            time, so a host that should run N jobs at once at a scope enrolls N slots
            (--slots N) — <name>, <name>-2 .. <name>-N, one dir and service each, the
            same labels on all. Re-running keeps the size it finds; a smaller --slots
            retires the surplus (asked first). Which repos may use an org host's slots is
            their runner group, and the repo this registration is for — the checkout's,
            or --repo's — is admitted to it. Agent labels sit in the '#{LabelContracts::AI_FLOW_GROUP.name}' group,
            which dev owns: created when missing, pinned to ai-flow's workflows, healed
            when the console drifted — nothing to remember; its selection is
            each repo's build concurrency on the host, so admission is deliberate.
            #{LabelContracts::ORCHESTRATOR_LABEL} sits in its own '#{LabelContracts::ORCHESTRATOR_GROUP.name}' group, same pin, open to
            every repo (nothing to gate; nothing admitted); mixing the two in --labels is
            refused — one enrollment, one group. --group names a
            human's group for other pools. A public repo may only use a pinned group;
            register refuses otherwise. A repo-scoped enrollment is that repo's alone
            (cellbound-3d's editor): its own label, which no org slot advertises, so its
            jobs never pool with the org's; its concurrency is its own --slots.

            Register never steals a registration. Runner names are unique per scope, and
            `config.sh --replace` would turn GitHub's refusal of a duplicate into a silent
            takeover of a runner that keeps running; so --replace is passed only for a name
            whose registration is this host's own — an enrollment of this family's (same
            scope, host and group) whose .runner id is the id GitHub holds — a name nothing
            holds enrolls without it, and any other collision refuses, naming the holder's
            labels and status: pass --name to enroll beside another family; unregister the
            stale dir when another host took this name after the registration was lost.

            Two kinds of ai-flow host. An agent host (--role agent; --ai-flow, or --labels over
            #{LabelContracts::AI_FLOW_AGENT_LABELS.join(" ")}) runs the agent: one slot is one agent
            run, sized for it, and the agent host bootstrap converges. An orchestrator
            (--role orchestrator) runs `/build --split`'s poll loop — API calls and
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
            survive a reboot: WSL stops a distro ~20 s after its last client
            session ends, and the runner's systemd service is not a session, so a Task
            Scheduler task at log on (`Start-WSL-<distro>-Runner`) holds one open —
            `#{WslKeepaliveTask::EXECUTE} --headless wsl.exe -d <distro> -u root -- sleep infinity`, no time
            limit, one instance; systemd is enabled in #{WslConf::PATH}; and .wslconfig is
            sized for the checkout's hint (the `dev up` step, asserted here). This needs
            the session's interop (powershell.exe), so run register from a shell opened in
            the distro on the Windows desktop, not over ssh; replacing a task a bootstrap
            script registered as an administrator takes one UAC prompt. A restart dev asks
            for is yours (`wsl --shutdown`, then `Start-ScheduledTask` or a new logon).

            An agent host is a Mac or a Linux dev host. Agent labels converge the
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
            image-built repo's agent runs inside the project's container, so
            agent labels for such a repo are refused there. A Mac
            bootstrapped before the one group name re-groups its root and `_work` trees from
            `#{AgentBootstrap::Darwin::LEGACY_GROUP}` to `#{DataRoot::GROUP}` on its next register.

            Examples:
              dev runner register                      # this repo's build host: repo scope, label = the repo name, named <hostname>
              dev runner register --labels ue-engine   # a build host with custom capabilities
              dev runner register --role agent         # the org agent host, the full ai-flow set, named <hostname>-agent (--ai-flow is the same)
              dev runner register --org --labels ai-build      # an agent host advertising a subset
              dev runner register --role agent --slots 3       # three jobs at once; this repo may use them
              dev runner register --role orchestrator --slots 4   # the orchestrator pool, on an always-on thin box
              dev runner register --role ue-farm               # a role this repo's dev.yml declares (runner_roles:)
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
            Cli::Flag.new(ORG_FLAG, desc: "enroll at the org scope (needs admin:org): implied by the agent and orchestrator roles; with --labels, an org pool instead of this repo's runner"),
            Cli::Flag.new(ROLE_FLAG, takes_value: true, desc: "what the slots are for: #{RunnerRole::BUILTINS.keys.join(" | ")} (builtin; org-scoped, named <host>-<role>), or a role dev.yml declares under runner_roles:; default: this repo's build host"),
            Cli::Flag.new(LABELS_FLAG, takes_value: true, desc: "comma-separated labels for a build host; default: the repo's name. An agent or orchestrator label is that role's sugar"),
            Cli::Flag.new(AI_FLOW_FLAG, desc: "--role #{RunnerRole::AGENT_NAME}: the agent host's ai-flow label set (#{LabelContracts::AI_FLOW_AGENT_LABELS.join(",")}); the orchestrator pool is --role #{RunnerRole::ORCHESTRATOR_NAME}"),
            Cli::Flag.new(SLOTS_FLAG, takes_value: true, desc: "how many jobs this host runs at once at this scope: N runners, <name>, <name>-2 .. <name>-N; default: what is enrolled, else 1"),
            Cli::Flag.new(GROUP_FLAG, takes_value: true, desc: "--org: the runner group the slots join (made once in the org's settings); agent labels imply '#{LabelContracts::AI_FLOW_GROUP.name}', #{LabelContracts::ORCHESTRATOR_LABEL} implies '#{LabelContracts::ORCHESTRATOR_GROUP.name}'; default: #{DEFAULT_GROUP}"),
            Cli::Flag.new(DIR_FLAG, takes_value: true, desc: "the runner directory (one slot); default: actions-runner-<role> under the enrollment owner's home (a build host: -<first label>), -<n> per further slot"),
            Cli::Flag.new(NAME_FLAG, takes_value: true, desc: "the runner's name on GitHub (slot 1; further slots are <name>-<n>); default: <hostname>-<role>, the bare hostname for a build host. A name another family holds at the scope is refused, never replaced"),
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
          # The one repo derivation (`--repo`, else the checkout's): the
          # build host's label, the operator pre-flight, the reach and the
          # group's access all read it — after the usage checks, so a bare
          # --org is told what it is missing rather than what gh could not
          # resolve.
          resolve_repo = memoized { @repo_resolver.call(args.value(REPO_FLAG)) }
          role = resolve_role(args, context, resolve_repo)
          # Scope is derived from the role (dev#566): a pinned role lives at
          # the org because only a group carries the pin; a build host is
          # its repo's — unless --labels names a custom set and --org makes
          # it an org pool, the one place the flag is an input.
          org = role.org_scoped? || args.flag?(ORG_FLAG)
          repo = resolve_repo.call
          slots = resolve_slots(args)
          contract = role.group
          labels = role.labels.join(",")
          config = RunnerSetupConfig.new(
            role: role,
            dir: args.value(DIR_FLAG),
            name: args.value(NAME_FLAG),
          )

          # The operator's login first, before sudo, brew or the engine: can
          # it do what this registration asks of it (mint tokens; at the org,
          # read and converge runner groups)? Refused, this is where it stops.
          @operator_access.check!(scope: org ? T.must(repo.split("/").first) : repo, org: org, ui: context.ui)

          # Who may land a job on these slots, as the role expects it
          # (Reach): said here so a build host for a public repo — any
          # workflow, a fork PR's YAML included (plans#5 Gap 1) — is refused
          # before anything converges. The comparison against what GitHub
          # holds is `dev runner status`'s.
          role.expected_reach(Dev::Reach::Target.new(repo: repo, public: @registry.repository(repo).public?))

          container = context.project&.project_images&.containerized? || false
          engine = context.project&.engine
          # The engine this host will build in, sized for this repo, before any
          # label contract (whose agent-host steps assume an engine exists).
          @engine_provisioner.provision!(resources: engine) if container

          # The host rule: who the enrollment belongs to. Its sudo work rides
          # the engine step's session; its gh login gates everything after;
          # and with a checkout, what that login can read of its lock is
          # checked now rather than discovered by a red run (HostReach).
          runner_user = @runner_user_factory.call(args.value(AS_FLAG), context.ui)
          if runner_user
            context.ui.frame("Host rule (#{runner_user.name})") do
              @data_root_provisioner&.provision!(ui: context.ui)
              runner_user.converge!
              runner_user.ensure_gh_authenticated!
              root = context.project&.root
              @reach_factory.call(runner_user).check!(@pins_reader.call(root)) if root
            end
          end

          # The WSL runner host: the logon keepalive, systemd and
          # `.wslconfig` a runner in a WSL2 distro needs to survive a reboot.
          # After the runner user (its wsl.conf write rides the same sudo
          # session), before any contract or enrollment: a host that goes
          # down at the next reboot is not one to enroll on.
          @wsl_runner_host&.converge!(resources: engine)

          # The agent host contract spawns the agent from the enrolling
          # user's service: the runner user on Linux, the operator on a Mac.
          # Its frame is named for the agent user, and opens only when there
          # is a contract to converge in it.
          contracts = @contracts_factory.call(labels, args.value(AGENT_USER_FLAG), runner_user&.name, context.ui)
          unless contracts.empty?
            context.ui.frame("Agent host (#{args.value(AGENT_USER_FLAG) || Dev::AgentBootstrap::DEFAULT_AGENT_USER})") do
              contracts.each do |contract|
                contract.converge!(
                  container: container,
                  cpus: engine&.cpus,
                  memory_gib: engine&.memory_gib,
                  disk_gib: engine&.disk_gib,
                )
              end
            end
          end

          setup = @runner_setup_factory.call(config, args.value(REPO_FLAG), org, runner_user, context.ui)
          scope = setup.resolve_scope
          yes = args.flag?(YES_FLAG)
          # The org-side contract first: the group the slots will join must
          # exist, with its access, before config.sh names it.
          group = contract && @groups.converge!(contract, org: scope, ui: context.ui)
          # --dir is the operator picking the dir: no discovery, no detection.
          # The one enrollment that can be this host's own there is the
          # dir's own record (`own`, below) — a name GitHub holds under any
          # other registration is refused there like anywhere else. The
          # runner user's home is where the rule puts enrollments; the
          # operator's is where the ones from before it are.
          discovery = runner_user ? @discovery.also_under(runner_user.home) : @discovery
          at_scope = config.dir ? [] : discovery.enrollments_for(scope)
          picked = config.dir ? [discovery.at(setup.resolve_dir)].compact.select { |enrollment| enrollment.scope == scope } : []
          # GitHub's record of each, looked up once: what tells the families
          # apart below, and what the amend path reads.
          known = (at_scope + picked).to_h { |enrollment| [enrollment.name, @registry.find(scope: scope, name: enrollment.name)] }
          enrollments, _others = partition_family(at_scope, known, role)
          # Before anything is retired or enrolled: an enrollment of this
          # host's whose record GitHub holds under another registration id
          # is a look-alike, not this host's — refused here, with nothing
          # changed.
          refuse_look_alikes!(scope, config.dir ? picked : enrollments, known, ui: context.ui)
          # Named from the family's own enrollments — the `--dir`'s record
          # when the operator picked the dir — else from the role.
          naming = resolve_naming(config.dir ? picked : enrollments, config, setup)
          by_slot, runners = enrolled_slots(scope, enrollments, naming, config, known)

          if superseded?(enrollments, by_slot, runners, runner_user)
            retire!(scope, enrollments, by_slot, runners, runner_user, yes: yes, ui: context.ui)
            # Fresh from here: named and placed as a family with nothing
            # enrolled would be, not from what was just torn down.
            naming = resolve_naming([], config, setup)
            by_slot = {}
            runners = {}
          end

          # How many slots: what --slots says, else what is enrolled (the
          # highest slot — a gap is re-filled), else one.
          count = slots || by_slot.keys.max || 1
          # The slots that will enroll rather than amend, and for each
          # whether config.sh may --replace what GitHub holds under its name
          # — asked of every one before any enrolls or the surplus retires,
          # so a name another family holds stops register with nothing
          # changed.
          fresh = (1..count).reject do |slot|
            enrollment = by_slot[slot]&.first
            enrollment && runners.key?(enrollment.name)
          end
          own = config.dir ? picked : enrollments
          replacing = fresh.to_h { |slot| [slot, replace?(scope, fresh_slot_name(slot, naming), own, known, ui: context.ui)] }
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

            replace = replacing.fetch(slot)
            slot_setup = setup
            if enrollment || slot > 1 || named_apart?(naming, config, setup) || replace
              # GitHub has lost this enrollment (or --name renames it): the
              # re-enrollment reuses the discovered dir, never a second one.
              # A slot beyond the first is named and placed from slot 1. A
              # family named apart from the hostname names slot 1 too — the
              # hostname is the other family's. And a slot taking its own
              # held name over is told it may.
              slot_config = RunnerSetupConfig.new(
                role: role,
                dir: enrollment&.dir || naming.slot_dir(slot),
                name: fresh_slot_name(slot, naming),
                replace: replace,
              )
              slot_setup = @runner_setup_factory.call(slot_config, args.value(REPO_FLAG), org, runner_user, context.ui)
            end
            slot_setup.run
            contracts.each { |contract| contract.after_enroll!(runner_dir: slot_setup.resolve_dir, slot: slot) }
          end

          converge_access!(scope, group, repo, ui: context.ui) if org
        end

        private

        # Who may use the slots: the repo this registration is for — the
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

        # The scope's enrollments split into this family's and the other
        # families'. A family is `(scope, host, role)`: the slots one
        # `register` enrolls. An enrollment GitHub still lists is this
        # role's when the role claims its labels (RunnerRole#claims?): they
        # oblige this role's group, or none — a bare label set is amended
        # into whichever role registers. One GitHub has lost is told by the
        # pool its own `.runner` record names: this role's pool is this
        # family's; Default (a registration placed in no group) is any
        # role's to take over; another role's pool is another family's.
        # Neither the dir's name nor the runner's is parsed for this. An
        # enrollment of another role is never sized, amended or retired
        # here.
        #
        # @param enrollments [Array<Dev::RunnerDiscovery::Enrollment>] every enrollment at the scope
        # @param known [Hash{String => Runner, nil}] GitHub's record by name; nil where lost
        # @param role [Dev::RunnerRole] this family's role
        # @return [[Array<Enrollment>, Array<Enrollment>]] this family's, the others'
        sig do
          params(
            enrollments: T::Array[Dev::RunnerDiscovery::Enrollment],
            known: T::Hash[String, T.nilable(Dev::RunnerRegistry::Runner)],
            role: RunnerRole,
          ).returns([T::Array[Dev::RunnerDiscovery::Enrollment], T::Array[Dev::RunnerDiscovery::Enrollment]])
        end
        def partition_family(enrollments, known, role)
          enrollments.partition do |enrollment|
            runner = known[enrollment.name]
            if runner
              role.claims?(runner.custom_labels)
            else
              enrollment.pool == RunnerRole::DEFAULT_POOL || enrollment.pool == role.pool_name
            end
          end
        end

        # How this host's slots at the scope are named: slot 1 by `--name`,
        # else by the one base the family's enrollments share (an enrolled
        # family keeps its names), else by the role (RunnerRole#slot_base):
        # `<hostname>-<role>` for a grouped or user role, the bare hostname
        # for a build host. Several roles share a host at one org scope and
        # runner names are unique there, so the role is in the name. A
        # collision this naming does not avoid is `replace?`'s refusal,
        # never a rename. Slot 1's dir is its enrollment's when one exists,
        # else the setup's default (`--dir` included).
        #
        # @param enrollments [Array<Dev::RunnerDiscovery::Enrollment>] this family's
        # @param config [Dev::RunnerSetupConfig]
        # @param setup [Dev::RunnerSetup]
        # @return [Dev::RunnerSlots]
        sig do
          params(
            enrollments: T::Array[Dev::RunnerDiscovery::Enrollment],
            config: RunnerSetupConfig,
            setup: Dev::RunnerSetup,
          ).returns(Dev::RunnerSlots)
        end
        def resolve_naming(enrollments, config, setup)
          bases = enrollments.map { |enrollment| Dev::RunnerSlots.base_of(enrollment.name) }.uniq
          base = config.name || (bases.length == 1 ? T.must(bases.first) : nil) || config.role.slot_base(setup.resolve_name)
          provisional = Dev::RunnerSlots.new(base: base, dir: setup.resolve_dir)
          first = enrollments.find { |enrollment| provisional.slot_of(enrollment.name) == 1 }
          first ||= enrollments.first if config.name && enrollments.length == 1
          Dev::RunnerSlots.new(base: base, dir: first ? first.dir : setup.resolve_dir)
        end

        # Whether the family's base is one the setup would not derive on its
        # own — a role's `<hostname>-<role>`, or `--name` — so slot 1 must be
        # told its name.
        #
        # @param naming [Dev::RunnerSlots]
        # @param config [Dev::RunnerSetupConfig]
        # @param setup [Dev::RunnerSetup]
        # @return [Boolean]
        sig { params(naming: Dev::RunnerSlots, config: RunnerSetupConfig, setup: Dev::RunnerSetup).returns(T::Boolean) }
        def named_apart?(naming, config, setup)
          naming.base != (config.name || setup.resolve_name)
        end

        # The name a fresh slot enrolls under: the family's naming — slot 1
        # as `<base>`, slot n as `<base>-<n>`, never two slots under one
        # name.
        #
        # @param slot [Integer] 1-based
        # @param naming [Dev::RunnerSlots]
        # @return [String]
        sig { params(slot: Integer, naming: Dev::RunnerSlots).returns(String) }
        def fresh_slot_name(slot, naming)
          naming.slot_name(slot)
        end

        # Refuse when a local enrollment's name is held on GitHub by a
        # registration that is not the one the enrollment records
        # Own is the registration, not the name: names are
        # reused (another machine with this hostname, enrolled after this
        # registration was lost), ids are not, so a `.runner` under the
        # name with another id is a look-alike — and `--replace`, or the
        # retire-and-enroll-fresh path, would take the other machine's
        # runner over. Said before anything is torn down or enrolled.
        #
        # @param scope [String]
        # @param enrollments [Array<Dev::RunnerDiscovery::Enrollment>] this host's candidates: the family's, or the `--dir`'s
        # @param known [Hash{String => Runner, nil}] GitHub's record by discovered name; nil where lost
        # @param ui [Ui] the refusal is said here before it is raised
        # @raise [RegistrationHeldError] when a name is held by another registration
        sig do
          params(
            scope: String,
            enrollments: T::Array[Dev::RunnerDiscovery::Enrollment],
            known: T::Hash[String, T.nilable(Dev::RunnerRegistry::Runner)],
            ui: Ui,
          ).void
        end
        def refuse_look_alikes!(scope, enrollments, known, ui:)
          enrollments.each do |enrollment|
            holder = known.fetch(enrollment.name) { @registry.find(scope: scope, name: enrollment.name) }
            next if holder.nil? || holder.id == enrollment.agent_id

            ui.note("{{x}} '#{enrollment.name}' at #{scope} is registered by another host under this family's name " \
              "(labels: #{holder.custom_labels.join(",")}, #{holder.status}); this host's #{enrollment.display_dir} records a registration " \
              "GitHub no longer holds — dev runner unregister it, then re-run")
            raise RegistrationHeldError, "nothing changed: '#{enrollment.name}' at #{scope} is not this host's registration to replace"
          end
        end

        # Whether config.sh may `--replace` the registration held under
        # `name` at the scope: no when nothing holds it (nothing
        # to replace); yes only when the holder is this host's own
        # registration — an enrollment of this family's (same scope, host
        # and group by partition_family's construction; the `--dir`'s own
        # record when the operator picked the dir) whose `.runner` id *is*
        # the id GitHub holds under the name. Own is the registration, not
        # the name (refuse_look_alikes! has already said so of any local
        # record under the name with another id). Any other holder is a refusal
        # naming it, since GitHub would refuse the duplicate and `--replace`
        # would turn that into a silent takeover of a runner that keeps
        # running. GitHub's record is read once per name: the discovered
        # names' from the partition's lookup, a fresh slot's here.
        #
        # @param scope [String]
        # @param name [String] the name the slot would enroll under
        # @param own [Array<Dev::RunnerDiscovery::Enrollment>] the enrollments that may be this host's own: the family's, or the `--dir`'s
        # @param known [Hash{String => Runner, nil}] GitHub's record by discovered name; nil where lost
        # @param ui [Ui] the refusal is said here before it is raised
        # @return [Boolean]
        # @raise [RegistrationHeldError] when a registration not this host's holds the name
        sig do
          params(
            scope: String,
            name: String,
            own: T::Array[Dev::RunnerDiscovery::Enrollment],
            known: T::Hash[String, T.nilable(Dev::RunnerRegistry::Runner)],
            ui: Ui,
          ).returns(T::Boolean)
        end
        def replace?(scope, name, own, known, ui:)
          holder = known.fetch(name) { @registry.find(scope: scope, name: name) }
          return false if holder.nil?

          return true if own.any? { |enrollment| enrollment.name == name && enrollment.agent_id == holder.id }

          ui.note("{{x}} '#{name}' at #{scope} is registered by another family " \
            "(labels: #{holder.custom_labels.join(",")}, #{holder.status}) — pass #{NAME_FLAG} to enroll beside it")
          raise RegistrationHeldError, "nothing changed: '#{name}' at #{scope} is another family's registration, not this one's to replace"
        end

        # The enrolled slots: by slot, the dirs enrolled under its name (one
        # is the steady state), and GitHub's record of each by name (absent
        # when GitHub has lost it). One enrollment under another name with
        # `--name` is a rename: it is slot 1, looked up under its new name —
        # the registry's answer says whether GitHub already knows the new
        # name (amend) or the re-enrollment renames.
        #
        # @param scope [String]
        # @param enrollments [Array<Dev::RunnerDiscovery::Enrollment>] this family's
        # @param naming [Dev::RunnerSlots]
        # @param config [Dev::RunnerSetupConfig]
        # @param known [Hash{String => Runner, nil}] GitHub's record by enrollment name; nil where lost
        # @return [[Hash{Integer => Array<Enrollment>}, Hash{String => Runner}]]
        sig do
          params(
            scope: String,
            enrollments: T::Array[Dev::RunnerDiscovery::Enrollment],
            naming: Dev::RunnerSlots,
            config: RunnerSetupConfig,
            known: T::Hash[String, T.nilable(Dev::RunnerRegistry::Runner)],
          ).returns([SlotMap, T::Hash[String, Dev::RunnerRegistry::Runner]])
        end
        def enrolled_slots(scope, enrollments, naming, config, known)
          by_slot = T.let({}, SlotMap)
          enrollments.each do |enrollment|
            slot = naming.slot_of(enrollment.name)
            (by_slot[slot] ||= []) << enrollment if slot
          end
          renamed = config.name && by_slot.empty? && enrollments.length == 1
          by_slot = { 1 => enrollments } if renamed

          runners = {}
          by_slot.values.flatten.each do |member|
            runner = renamed ? @registry.find(scope: scope, name: T.must(config.name)) : known[member.name]
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

        # The role this registration declares (dev#566), by precedence:
        # `--role` (a builtin by name, else one the checkout's dev.yml
        # declares under `runner_roles:`; anything else is refused pointing
        # at dev.yml — the drift path), `--ai-flow` (the agent), `--labels`
        # (an agent or orchestrator label is that role's sugar; a bare set
        # is a build host with those capabilities — in a human's `--group`
        # at the org), else the repo's build host: its name as GitHub spells
        # it, lowercased (Dev::EnrolledRunner — what the remote dispatch's
        # lookup asks GitHub for). Org scope has nothing to derive a role
        # from, so bare --org is a usage error; so is bare register outside
        # a project, since the checkout is also what sizes the engine. A
        # role's labels are its declaration: `--role x --labels y` is
        # refused, as is `--org` with a dev.yml role (org scope is
        # builtin-only) and `--group` with a pinned role (it names its own).
        #
        # @param args [Cli::ParsedArgs]
        # @param context [Dev::Cli::ExecutionContext]
        # @param resolve_repo [Proc] derives the repo this registration is for, asked only when the label derives from it
        # @return [Dev::RunnerRole]
        # @raise [ArgumentError] on an underivable or contradictory request
        # @raise [Dev::EnrolledRunner::MalformedRepoError] when the repo (`--repo`) is not an owner/repo
        # @raise [Dev::RunnerSetup::Error] when gh cannot resolve the checkout
        sig { params(args: Cli::ParsedArgs, context: ExecutionContext, resolve_repo: T.proc.returns(String)).returns(RunnerRole) }
        def resolve_role(args, context, resolve_repo)
          org = args.flag?(ORG_FLAG)
          named_role = args.value(ROLE_FLAG)
          explicit = args.value(LABELS_FLAG)
          ai_flow = args.flag?(AI_FLOW_FLAG)
          group = args.value(GROUP_FLAG)
          raise ArgumentError, "runner groups partition an org's runners — #{GROUP_FLAG} goes with #{ORG_FLAG}" if group && !org

          role = if named_role
            if explicit || ai_flow
              raise ArgumentError,
                "#{ROLE_FLAG} #{named_role} declares the labels — drop #{explicit ? LABELS_FLAG : AI_FLOW_FLAG}"
            end
            declared_role(named_role, context, org)
          elsif ai_flow
            if explicit
              raise ArgumentError,
                "--ai-flow enrolls the agent host's ai-flow set (#{LabelContracts::AI_FLOW_AGENT_LABELS.join(",")}); " \
                  "pass --labels alone for a custom set"
            end
            RunnerRole::AGENT
          elsif explicit
            RunnerRole.for_labels(explicit.split(",").map(&:strip), group: group && RunnerGroupContract.new(name: group))
          else
            if org
              raise ArgumentError,
                "an org runner's role is not derivable — pass #{ROLE_FLAG} #{RunnerRole::BUILTINS.keys.join("|")}, --ai-flow (the agent host) or --labels"
            end
            if context.project.nil?
              raise ArgumentError,
                "the repo label derives from the enclosing checkout (which also sizes the engine) — " \
                  "run inside one or pass --labels"
            end
            RunnerRole.build_host(labels: [Dev::EnrolledRunner.for(resolve_repo.call).label])
          end

          if group && role.org_scoped? && group != T.must(role.group).name
            raise ArgumentError,
              "these labels sit in the '#{T.must(role.group).name}' runner group (pinned to ai-flow's workflows) — drop #{GROUP_FLAG} #{group}"
          end
          role
        end

        # The role `--role` names: a builtin, else the checkout's dev.yml
        # declaration. A dev.yml role is its repo's (org scope is
        # builtin-only) and sits in no group.
        #
        # @param name [String]
        # @param context [Dev::Cli::ExecutionContext]
        # @param org [Boolean] `--org`
        # @return [Dev::RunnerRole]
        # @raise [ArgumentError]
        sig { params(name: String, context: ExecutionContext, org: T::Boolean).returns(RunnerRole) }
        def declared_role(name, context, org)
          builtin = RunnerRole.builtin(name)
          return builtin if builtin

          declared = context.project&.runner_roles&.fetch(name, nil)
          unless declared
            raise ArgumentError,
              "runner role '#{name}' is neither builtin (#{RunnerRole::BUILTINS.keys.join(", ")}) nor declared in " \
                "#{context.project ? "this checkout's" : "a"} dev.yml — declare it once: runner_roles: { #{name}: { labels: [...] } }"
          end
          if org
            raise ArgumentError,
              "runner role '#{name}' is this repo's (dev.yml roles enroll at repo scope; org scope is builtin-only) — drop #{ORG_FLAG}"
          end

          declared
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
