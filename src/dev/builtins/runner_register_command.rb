# typed: strict
# frozen_string_literal: true

require "dev/cli/flag_parser"
require "dev/command"
require "dev/engine_provisioner"
require "dev/label_contracts"
require "dev/project_manifest"
require "dev/runner_discovery"
require "dev/runner_registry"
require "dev/runner_setup"
require "dev/runner_setup_config"

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
    # user. A leaf of the `runner` group (RunnerStatusCommand is the other).
    class RunnerRegisterCommand < BuiltinCommand
      extend T::Sig

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
        enrollment = config.dir ? nil : @discovery.for_scope(setup.resolve_scope)
        if enrollment && amend_enrollment(setup.resolve_scope, enrollment, config)
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

      # The amend path: when the discovered enrollment still exists on
      # GitHub, converge its custom labels in place — the service, name,
      # and dir all stay put. False when GitHub no longer knows the runner
      # (the caller re-enrolls).
      #
      # @param scope [String]
      # @param enrollment [Dev::RunnerDiscovery::Enrollment]
      # @param config [Dev::RunnerSetupConfig]
      # @return [Boolean] whether the enrollment was converged in place
      sig do
        params(scope: String, enrollment: Dev::RunnerDiscovery::Enrollment, config: RunnerSetupConfig)
          .returns(T::Boolean)
      end
      def amend_enrollment(scope, enrollment, config)
        name = config.name || enrollment.name
        runner = @registry.find(scope: scope, name: name)
        return false if runner.nil?

        desired = config.labels.split(",")
        if runner.custom_labels.sort == desired.sort
          @out.puts ">>> Runner '#{name}' already serves #{scope} with labels #{config.labels} — nothing to amend."
        else
          @out.puts ">>> Amending labels of '#{name}' at #{scope}: " \
                    "#{runner.custom_labels.join(",")} -> #{config.labels} ..."
          @registry.amend!(scope: scope, runner_id: runner.id, labels: desired)
        end
        true
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
