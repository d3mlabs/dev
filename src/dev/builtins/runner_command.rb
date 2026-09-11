# typed: strict
# frozen_string_literal: true

require "dev/cli/flag_parser"
require "dev/command"
require "dev/label_contracts"
require "dev/runner_setup"
require "dev/runner_setup_config"
require "dev/runner_status"

module Dev
  module Builtins
    # `dev runner <register|status>` — layers 3+4 of the machine doctrine
    # (plans#26): converge, then enroll.
    #
    # `register` first converges the label contracts of every advertised
    # label (agent-capability labels carry the agent host bootstrap; bare
    # labels converge nothing), then performs the enrollment ceremony —
    # unchanged from the old `runner-setup`, which survives as an alias —
    # and finally the post-enrollment steps against the enrolled runner
    # dir. Repo-scoped by default, org-scoped with `--org`;
    # `--labels`/`--dir`/`--name`/`--repo` override the dev.yml block;
    # `--agent-user` overrides the ai-agent default run-as user.
    #
    # Exists only when a project declares a `runner:` block (the composition
    # root gates it), so the command surfaces only where it applies.
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
        T.proc.params(
          config: RunnerSetupConfig,
          container_required: T::Boolean,
        ).returns(Dev::RunnerStatus)
      end

      sig do
        params(
          runner_setup_factory: RunnerSetupFactory,
          contracts_factory: ContractsFactory,
          runner_status_factory: StatusFactory,
          flag_parser: Cli::FlagParser,
          implied_subcommand: T.nilable(String),
        ).void
      end
      def initialize(
        runner_setup_factory: ->(config, repo, org) { Dev::RunnerSetup.new(config:, repo:, org:) },
        contracts_factory: ->(labels, agent_user) { Dev::LabelContracts.for(labels, agent_user: agent_user) },
        runner_status_factory: ->(config, container_required) {
          Dev::RunnerStatus.new(config: config, container_required: container_required)
        },
        flag_parser: Cli::FlagParser.new,
        implied_subcommand: nil
      )
        super()
        @runner_setup_factory = runner_setup_factory
        @contracts_factory = contracts_factory
        @runner_status_factory = runner_status_factory
        @flag_parser = flag_parser
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

      # Converge, then enroll, then the steps the enrollment enables.
      #
      # @param args [Array<String>]
      # @param context [Dev::ExecutionContext]
      sig { params(args: T::Array[String], context: ExecutionContext).void }
      def register(args, context)
        cfg = context.project!.runner
        raise ArgumentError, "no `runner:` block in dev.yml" if cfg.nil?

        cfg = config_with_flag_overrides(cfg, args)
        contracts = @contracts_factory.call(cfg.labels, @flag_parser.value(args, "--agent-user"))

        container = context.project!.build_container
        contracts.each do |contract|
          contract.converge!(
            container: !container.nil?,
            cpus: container&.resources&.cpus,
            memory_gib: container&.resources&.memory_gib,
          )
        end

        setup = @runner_setup_factory.call(
          cfg,
          # nil repo lets RunnerSetup fall back to `gh repo view`.
          @flag_parser.value(args, "--repo"),
          args.include?("--org"),
        )
        setup.run

        contracts.each { |contract| contract.after_enroll!(runner_dir: setup.resolve_dir) }
      end

      # Inspect-only: the block's expected identity vs the enrolled reality
      # plus every advertised label's contract facts.
      #
      # @param args [Array<String>]
      # @param context [Dev::ExecutionContext]
      sig { params(args: T::Array[String], context: ExecutionContext).void }
      def status(args, context)
        cfg = context.project!.runner
        raise ArgumentError, "no `runner:` block in dev.yml" if cfg.nil?

        cfg = config_with_flag_overrides(cfg, args)
        @runner_status_factory.call(cfg, !context.project!.build_container.nil?).report
      end

      # A copy of the dev.yml runner block with any `--labels` / `--dir` /
      # `--name` CLI overrides applied. The block describes the repo's
      # default runner host; overrides let a different host (e.g. the shared
      # Mac registering org-wide) reuse the same command without editing
      # dev.yml.
      #
      # @param cfg [Dev::RunnerSetupConfig]
      # @param args [Array<String>]
      # @return [Dev::RunnerSetupConfig]
      sig { params(cfg: RunnerSetupConfig, args: T::Array[String]).returns(RunnerSetupConfig) }
      def config_with_flag_overrides(cfg, args)
        RunnerSetupConfig.new(
          labels: @flag_parser.value(args, "--labels") || cfg.labels,
          dir: @flag_parser.value(args, "--dir") || cfg.dir,
          name: @flag_parser.value(args, "--name") || cfg.name,
          version: cfg.version,
        )
      end
    end
  end
end
