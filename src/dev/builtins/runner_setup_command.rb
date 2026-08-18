# typed: strict
# frozen_string_literal: true

require "dev/builtin_body"
require "dev/cli/flag_parser"
require "dev/runner_setup"
require "dev/runner_setup_config"

module Dev
  module Builtins
    # `dev runner-setup` registers the current host as a self-hosted GitHub
    # Actions runner — repo-scoped by default, org-scoped with `--org` (one
    # runner serving every repo in the org, the shape ai-flow's shared pools
    # want). Exists only when a project declares a `runner:` block (the
    # composition root gates it), so the command surfaces only where it
    # applies. dev owns the install logic (one shared implementation) so
    # repos declare just their runner identity instead of vendoring a
    # bespoke setup script. `--labels`/`--dir`/`--name` override the block
    # for hosts that differ from the repo default (e.g. registering the Mac
    # org-wide from a repo whose block describes the CI box).
    class RunnerSetupCommand
      extend T::Sig
      include BuiltinBody

      # Builds the RunnerSetup for the resolved config and flags; injected
      # so tests can observe the wiring without touching gh or the host.
      RunnerSetupFactory = T.type_alias do
        T.proc.params(
          config: RunnerSetupConfig,
          repo: T.nilable(String),
          org: T::Boolean,
        ).returns(Dev::RunnerSetup)
      end

      sig { params(runner_setup_factory: RunnerSetupFactory, flag_parser: Cli::FlagParser).void }
      def initialize(
        runner_setup_factory: ->(config, repo, org) { Dev::RunnerSetup.new(config:, repo:, org:) },
        flag_parser: Cli::FlagParser.new
      )
        @runner_setup_factory = T.let(runner_setup_factory, RunnerSetupFactory)
        @flag_parser = T.let(flag_parser, Cli::FlagParser)
      end

      sig { override.returns(String) }
      def desc
        "Register this host as a self-hosted GitHub Actions runner (repo-scoped, or org-wide with --org)"
      end

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        cfg = context.runner
        raise ArgumentError, "no `runner:` block in dev.yml" if cfg.nil?

        @runner_setup_factory.call(
          config_with_flag_overrides(cfg, args),
          # nil repo lets RunnerSetup fall back to `gh repo view`.
          @flag_parser.value(args, "--repo"),
          args.include?("--org"),
        ).run
      end

      private

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
