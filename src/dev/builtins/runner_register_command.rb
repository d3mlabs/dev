# typed: strict
# frozen_string_literal: true

require "dev/cli/flag_parser"
require "dev/command"
require "dev/confirmer"
require "dev/engine_provisioner"
require "dev/label_contracts"
require "dev/project_manifest"
require "dev/runner_discovery"
require "dev/runner_registry"
require "dev/runner_setup"
require "dev/runner_setup_config"
require "dev/runner_teardown"

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

      YES_FLAG = "--yes"

      # Builds the RunnerSetup for the resolved config and flags; injected
      # so tests can observe the wiring without touching gh or the host.
      RunnerSetupFactory = T.type_alias do
        T.proc.params(
          config: RunnerSetupConfig,
          repo: T.nilable(String),
          org: T::Boolean,
        ).returns(Dev::RunnerSetup)
      end

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
          flag_parser: Cli::FlagParser,
          out: T.any(IO, StringIO),
        ).void
      end
      def initialize(
        runner_setup_factory: ->(config, repo, org) { Dev::RunnerSetup.new(config:, repo:, org:) },
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
        flag_parser: Cli::FlagParser.new,
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
        @flag_parser = flag_parser
        @out = out
      end

      sig { override.returns(String) }
      def desc = "Enroll this host as a self-hosted runner, converging label contracts (--org, --labels, --ai-flow)"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Lifecycle

      # Converge, then enroll (or amend), then the steps the enrollment
      # enables.
      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        org = args.include?("--org")
        labels = resolve_labels(args, context, org)
        config = RunnerSetupConfig.new(
          labels: labels,
          dir: @flag_parser.value(args, "--dir"),
          name: @flag_parser.value(args, "--name"),
        )

        container = context.project&.build_container
        # The engine this host will build in, sized for this repo, before any
        # label contract (whose agent-host steps assume an engine exists).
        @engine_provisioner.provision!(resources: container.resources) if container

        contracts = @contracts_factory.call(labels, @flag_parser.value(args, "--agent-user"))
        contracts.each do |contract|
          contract.converge!(
            container: !container.nil?,
            cpus: container&.resources&.cpus,
            memory_gib: container&.resources&.memory_gib,
          )
        end

        setup = @runner_setup_factory.call(config, @flag_parser.value(args, "--repo"), org)
        scope = setup.resolve_scope
        # --dir is the operator picking the dir: no discovery, no detection.
        enrollments = config.dir ? [] : @discovery.enrollments_for(scope)
        runner = enrollments.empty? ? nil : @registry.find(scope: scope, name: config.name || T.must(enrollments.first).name)

        if superseded?(enrollments, runner)
          retire!(scope, enrollments, runner, yes: args.include?(YES_FLAG))
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
          setup = @runner_setup_factory.call(config, @flag_parser.value(args, "--repo"), org)
        end
        setup.run
        contracts.each { |contract| contract.after_enroll!(runner_dir: setup.resolve_dir) }
      end

      private

      # Whether the enrollment on disk is not what is serving GitHub: more
      # than one local enrollment for the scope (one name, one registration
      # — the rest are `--replace` leftovers), or the runner GitHub holds
      # is offline (nothing runs it). One enrollment that GitHub has lost
      # is not this case: the re-enrollment path reuses its dir.
      #
      # @param enrollments [Array<Dev::RunnerDiscovery::Enrollment>]
      # @param runner [Dev::RunnerRegistry::Runner, nil]
      # @return [Boolean]
      sig do
        params(enrollments: T::Array[Dev::RunnerDiscovery::Enrollment], runner: T.nilable(Dev::RunnerRegistry::Runner))
          .returns(T::Boolean)
      end
      def superseded?(enrollments, runner)
        enrollments.length > 1 || (!runner.nil? && !runner.online?)
      end

      # List the superseded enrollments, ask, and unregister them all —
      # or, declined, raise with the by-hand remedy having changed nothing.
      #
      # @param scope [String]
      # @param enrollments [Array<Dev::RunnerDiscovery::Enrollment>]
      # @param runner [Dev::RunnerRegistry::Runner, nil]
      # @param yes [Boolean] `--yes`: answer the question without asking
      # @raise [SupersededEnrollmentsError] when the operator declines
      sig do
        params(
          scope: String,
          enrollments: T::Array[Dev::RunnerDiscovery::Enrollment],
          runner: T.nilable(Dev::RunnerRegistry::Runner),
          yes: T::Boolean,
        ).void
      end
      def retire!(scope, enrollments, runner, yes:)
        signs = []
        signs << "#{enrollments.length} local enrollments" if enrollments.length > 1
        signs << "GitHub lists '#{T.must(enrollments.first).name}' offline" if runner && !runner.online?
        @out.puts ">>> #{scope} has #{signs.join(" and ")} — the enrollment on disk is not what is serving GitHub:"
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
      sig { params(args: T::Array[String], context: ExecutionContext, org: T::Boolean).returns(String) }
      def resolve_labels(args, context, org)
        explicit = @flag_parser.value(args, "--labels")
        ai_flow = args.include?("--ai-flow")
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
        repo_label(@repo_resolver.call(@flag_parser.value(args, "--repo")))
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
