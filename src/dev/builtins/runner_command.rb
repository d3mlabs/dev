# typed: strict
# frozen_string_literal: true

require "dev/cli/flag_parser"
require "dev/command"
require "dev/label_contracts"
require "dev/project_manifest"
require "dev/runner_discovery"
require "dev/runner_registry"
require "dev/runner_setup"
require "dev/runner_setup_config"
require "dev/runner_status"

module Dev
  module Builtins
    # `dev runner <register|status>` — layers 3+4 of the machine doctrine
    # (plans#26): converge, then enroll. Scope and labels compose
    # orthogonally, with derived defaults so the common enrollments need no
    # declaration anywhere (the dev.yml `runner:` block is retired):
    #
    #   dev runner register                    # repo scope; label = the project slug
    #   dev runner register --labels ue-engine # repo scope, custom roles
    #   dev runner register --org --ai-flow    # org agent host, the full ai-flow set
    #   dev runner register --org --labels ai-build  # org custom pool
    #
    # register is idempotent and self-healing: it converges every advertised
    # label's contract (agent-capability labels carry the agent host
    # bootstrap; bare labels converge nothing), then looks for an existing
    # enrollment at the target scope (RunnerDiscovery — every local runner
    # dir, so dir names never matter) and amends its labels in place on
    # GitHub (RunnerRegistry) instead of re-enrolling; only a scope nothing
    # serves gets the full enrollment ceremony (RunnerSetup, unchanged from
    # the old `runner-setup`, which survives as an alias).
    #
    # Enrollment state is inspected, never recorded: the labels live on
    # GitHub, the scope in the runner dir's own .runner record — nothing in
    # dev.yml, Settings, or any inventory file.
    #
    # `--org` needs no project; bare register derives its label from the
    # enclosing checkout's manifest name. `--dir`/`--name`/`--repo` override
    # the enrollment identity; `--agent-user` the ai-agent default run-as
    # user.
    class RunnerCommand < BuiltinCommand
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

      # Builds the status inspector; injected for tests.
      StatusFactory = T.type_alias do
        T.proc.params(container_required: T::Boolean).returns(Dev::RunnerStatus)
      end

      sig do
        params(
          runner_setup_factory: RunnerSetupFactory,
          contracts_factory: ContractsFactory,
          runner_status_factory: StatusFactory,
          discovery: Dev::RunnerDiscovery,
          registry: T.untyped,
          flag_parser: Cli::FlagParser,
          out: T.any(IO, StringIO),
          implied_subcommand: T.nilable(String),
        ).void
      end
      def initialize(
        runner_setup_factory: ->(config, repo, org) { Dev::RunnerSetup.new(config:, repo:, org:) },
        contracts_factory: ->(labels, agent_user) { Dev::LabelContracts.for(labels, agent_user: agent_user) },
        runner_status_factory: ->(container_required) { Dev::RunnerStatus.new(container_required:) },
        discovery: Dev::RunnerDiscovery.new,
        # The GitHub boundary (#find/#amend!); T.untyped so tests fake it.
        registry: Dev::RunnerRegistry.new,
        flag_parser: Cli::FlagParser.new,
        out: $stdout,
        implied_subcommand: nil
      )
        super()
        @runner_setup_factory = runner_setup_factory
        @contracts_factory = contracts_factory
        @runner_status_factory = runner_status_factory
        @discovery = discovery
        @registry = registry
        @flag_parser = flag_parser
        @out = out
        @implied_subcommand = implied_subcommand
      end

      sig { override.returns(String) }
      def desc
        "Enroll or inspect this host as a self-hosted runner (runner register|status), converging label contracts"
      end

      sig { override.returns(Command::Category) }
      def category = Command::Category::Lifecycle

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        subcommand, rest = resolve_subcommand(args)
        case subcommand
        when "register"
          register(rest, context)
        when "status"
          status(rest, context)
        else
          raise ArgumentError, "usage: dev runner <register|status> [flags]"
        end
      end

      private

      # The subcommand and its args: implied for aliases (`dev runner-setup`
      # is `dev runner register`), else the first arg.
      #
      # @param args [Array<String>]
      # @return [Array(String, Array<String>)]
      sig { params(args: T::Array[String]).returns([T.nilable(String), T::Array[String]]) }
      def resolve_subcommand(args)
        return [@implied_subcommand, args] if @implied_subcommand

        [args.first, args.drop(1)]
      end

      # Converge, then enroll (or amend), then the steps the enrollment
      # enables.
      #
      # @param args [Array<String>]
      # @param context [Dev::ExecutionContext]
      sig { params(args: T::Array[String], context: ExecutionContext).void }
      def register(args, context)
        org = args.include?("--org")
        labels = resolve_labels(args, context, org)
        config = RunnerSetupConfig.new(
          labels: labels,
          dir: @flag_parser.value(args, "--dir"),
          name: @flag_parser.value(args, "--name"),
        )

        contracts = @contracts_factory.call(labels, @flag_parser.value(args, "--agent-user"))
        container = context.project&.build_container
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
      # enclosing project's slug. Org scope has nothing to derive from, so
      # bare --org is a usage error, as is bare register outside a project.
      #
      # @param args [Array<String>]
      # @param context [Dev::ExecutionContext]
      # @param org [Boolean]
      # @return [String] comma-separated labels (config.sh shape)
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

        project = context.project
        if project.nil?
          raise ArgumentError,
            "the repo label derives from the enclosing project — run inside a checkout or pass --labels"
        end
        ProjectManifest.slug(project.name)
      end

      # Inspect-only: this machine's discovered enrollments and their
      # contract facts (see Dev::RunnerStatus).
      #
      # @param args [Array<String>]
      # @param context [Dev::ExecutionContext]
      sig { params(args: T::Array[String], context: ExecutionContext).void }
      def status(args, context)
        _ = args
        @runner_status_factory.call(!context.project&.build_container.nil?).report
      end
    end
  end
end
