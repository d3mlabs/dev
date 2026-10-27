# typed: strict
# frozen_string_literal: true

require "dev/command"
require "dev/confirmer"
require "dev/deps/lockfile"
require "dev/engine_provisioner"
require "dev/host_reach"
require "dev/label_contracts"
require "dev/linux_data_root_provisioner"
require "dev/project_manifest"
require "dev/runner_discovery"
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
    #
    # register is idempotent and self-healing: when the enclosing checkout
    # declares `build.container`, it first brings the engine up for that
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
    # enrolls (its `build.container` hint sizes the engine) and derives its
    # label from that repo's name — the GitHub spelling, lowercased, since a
    # repo-scoped runner is that repo's object and the workflows targeting it
    # live there; dev.yml `name:` is the package identity and may differ.
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

      ORG_FLAG = "--org"
      LABELS_FLAG = "--labels"
      AI_FLOW_FLAG = "--ai-flow"
      DIR_FLAG = "--dir"
      NAME_FLAG = "--name"
      REPO_FLAG = "--repo"
      AGENT_USER_FLAG = "--agent-user"
      AS_FLAG = "--as"
      YES_FLAG = "--yes"

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
        out: $stdout
      )
        super()
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
          find gh. Register refuses to enroll until it has a gh login — the machine
          user's token (read access to what the jobs fetch), pasted once:
            #{Dev::RunnerUser.new(name: Dev::RunnerUser::DEFAULT_NAME).login_command}
          An enrollment running as anyone else is drift: register offers to retire it
          and enroll fresh as the runner user. On macOS the enrollment is yours (a
          per-user LaunchAgent); the agent user is the second identity there.

          Examples:
            dev runner register                      # repo scope; label = the repo name
            dev runner register --labels ue-engine   # repo scope, custom roles
            dev runner register --org --ai-flow      # org agent host, the full ai-flow set
            dev runner register --org --labels ai-build
        DESC
      end

      sig { override.returns(Command::Category) }
      def category = Command::Category::Lifecycle

      sig { override.returns(T::Array[Cli::Flag]) }
      def flags
        [
          Cli::Flag.new(ORG_FLAG, desc: "enroll at the org scope (needs admin:org); labels are required"),
          Cli::Flag.new(LABELS_FLAG, takes_value: true, desc: "comma-separated labels; default: the repo's name"),
          Cli::Flag.new(AI_FLOW_FLAG, desc: "the full ai-flow label set (#{LabelContracts::AI_FLOW_LABELS.join(",")})"),
          Cli::Flag.new(DIR_FLAG, takes_value: true, desc: "the runner directory; default: actions-runner-<first label> under the enrollment owner's home"),
          Cli::Flag.new(NAME_FLAG, takes_value: true, desc: "the runner's name on GitHub; default: the hostname"),
          Cli::Flag.new(REPO_FLAG, takes_value: true, desc: "enroll for owner/repo instead of the enclosing checkout"),
          Cli::Flag.new(AGENT_USER_FLAG, takes_value: true, desc: "the OS user agent labels run the agent as; default: #{AgentBootstrap::DEFAULT_AGENT_USER}"),
          Cli::Flag.new(AS_FLAG, takes_value: true, desc: "Linux: the OS user the runner service runs as; default: #{Dev::RunnerUser::DEFAULT_NAME}"),
          Cli::Flag.new(YES_FLAG, desc: "unregister superseded enrollments without asking"),
        ]
      end

      # Converge, then enroll (or amend), then the steps the enrollment
      # enables.
      sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
      def call(args:, context:)
        org = args.flag?(ORG_FLAG)
        labels = resolve_labels(args, context, org)
        config = RunnerSetupConfig.new(
          labels: labels,
          dir: args.value(DIR_FLAG),
          name: args.value(NAME_FLAG),
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
          runner_user.ensure_gh_authenticated!
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
        # --dir is the operator picking the dir: no discovery, no detection.
        # The runner user's home is where the rule puts enrollments; the
        # operator's is where the ones from before it are.
        discovery = runner_user ? @discovery.also_under(runner_user.home) : @discovery
        enrollments = config.dir ? [] : discovery.enrollments_for(scope)
        runner = enrollments.empty? ? nil : @registry.find(scope: scope, name: config.name || T.must(enrollments.first).name)

        if superseded?(enrollments, runner, runner_user)
          retire!(scope, enrollments, runner, runner_user, yes: args.flag?(YES_FLAG))
          enrollments = []
          runner = nil
        end

        enrollment = enrollments.first
        if enrollment && runner
          amend_enrollment(scope, enrollment, runner, config)
          contracts.each { |contract| contract.after_enroll!(runner_dir: enrollment.dir) }
          return
        end

        if enrollment
          # GitHub has lost this enrollment (or --name renames it): the
          # re-enrollment reuses the discovered dir, never a second one.
          config = RunnerSetupConfig.new(labels: labels, dir: enrollment.dir, name: config.name)
          setup = @runner_setup_factory.call(config, args.value(REPO_FLAG), org, runner_user)
        end
        setup.run
        contracts.each { |contract| contract.after_enroll!(runner_dir: setup.resolve_dir) }
      end

      private

      # Whether the enrollment on disk is not what is serving GitHub: more
      # than one local enrollment for the scope (one name, one registration
      # — the rest are `--replace` leftovers), or the runner GitHub holds
      # is offline (nothing runs it), or — under the host rule — an
      # enrollment runs as someone other than the runner user. One
      # enrollment that GitHub has lost is not this case: the re-enrollment
      # path reuses its dir.
      #
      # @param enrollments [Array<Dev::RunnerDiscovery::Enrollment>]
      # @param runner [Dev::RunnerRegistry::Runner, nil]
      # @param runner_user [Dev::RunnerUser, nil] the host rule's user
      # @return [Boolean]
      sig do
        params(
          enrollments: T::Array[Dev::RunnerDiscovery::Enrollment],
          runner: T.nilable(Dev::RunnerRegistry::Runner),
          runner_user: T.nilable(Dev::RunnerUser),
        ).returns(T::Boolean)
      end
      def superseded?(enrollments, runner, runner_user)
        enrollments.length > 1 || (!runner.nil? && !runner.online?) || !drifted(enrollments, runner_user).empty?
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
      # @param enrollments [Array<Dev::RunnerDiscovery::Enrollment>]
      # @param runner [Dev::RunnerRegistry::Runner, nil]
      # @param runner_user [Dev::RunnerUser, nil] the host rule's user
      # @param yes [Boolean] `--yes`: answer the question without asking
      # @raise [SupersededEnrollmentsError] when the operator declines
      sig do
        params(
          scope: String,
          enrollments: T::Array[Dev::RunnerDiscovery::Enrollment],
          runner: T.nilable(Dev::RunnerRegistry::Runner),
          runner_user: T.nilable(Dev::RunnerUser),
          yes: T::Boolean,
        ).void
      end
      def retire!(scope, enrollments, runner, runner_user, yes:)
        signs = []
        signs << "#{enrollments.length} local enrollments" if enrollments.length > 1
        signs << "GitHub lists '#{T.must(enrollments.first).name}' offline" if runner && !runner.online?
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
        repo_label(@repo_resolver.call(args.value(REPO_FLAG)))
      end

      # GitHub matches runner labels case-insensitively but stores them as
      # created; lowercasing keeps the amend compare exact. Dashes stay —
      # labels allow them, and the repo name is the identity.
      #
      # @param repo [String] "owner/repo"
      # @return [String] the repo name, lowercased
      sig { params(repo: String).returns(String) }
      def repo_label(repo)
        T.must(repo.split("/").last).downcase
      end
    end
  end
end
