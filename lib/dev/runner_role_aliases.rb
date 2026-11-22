# typed: strict
# frozen_string_literal: true

require "dev/runner_group_contract"
require "dev/runner_role"

module Dev
  # The one-release afterlife of the `agent` and `orchestrator` builtin
  # roles, which left dev for ai-flow's own dev.yml (plans#76): `dev
  # runner register --ai-flow` and `--labels ai-orchestrator` still
  # resolve, to the declaration ai-flow carries, pinned at `@main` as the
  # builtins were — and warn that the next release drops them. Everything
  # here is ai-flow's vocabulary, kept only so a host registered on the
  # old flags re-converges and reads in `dev runner status` until it is
  # re-registered from an ai-flow checkout (`--org --role agent`,
  # `--org --role orchestrator`). Delete this file with the flags.
  class RunnerRoleAliases
    extend T::Sig

    # The flag and the label set that alias each role.
    AI_FLOW_FLAG = "--ai-flow"
    ORCHESTRATOR_LABEL = "ai-orchestrator"

    # ai-flow's two reusable workflows at `main` — the pin the builtin
    # groups carried. A declared role pins the project's series instead.
    WORKFLOWS_AT_MAIN = T.let(
      %w[
        d3mlabs/ai-flow/.github/workflows/ai-commands.yml@refs/heads/main
        d3mlabs/ai-flow/.github/workflows/origin-firing.yml@refs/heads/main
      ].freeze,
      T::Array[String],
    )

    # The agent host: one label per slash command, the `ai-flow` group
    # (selected repos — a repo's build concurrency on the host), jobs as
    # `ai-agent`.
    AGENT = T.let(
      RunnerRole.declared(
        name: "agent",
        labels: %w[ai-ask ai-edit ai-split ai-build ai-learn],
        group: RunnerGroupContract.new(name: "ai-flow", workflows: WORKFLOWS_AT_MAIN),
        job_identity: "ai-agent",
      ),
      RunnerRole,
    )

    # The orchestrator pool: `/build --split`'s poll loop, its own group
    # open to every repo, no job identity.
    ORCHESTRATOR = T.let(
      RunnerRole.declared(
        name: "orchestrator",
        labels: [ORCHESTRATOR_LABEL],
        group: RunnerGroupContract.new(name: "ai-orchestrator", workflows: WORKFLOWS_AT_MAIN, visibility: RunnerGroupContract::ALL),
      ),
      RunnerRole,
    )

    # Both, by name — what `dev runner status` reads a host's slots against
    # until they are re-registered from the declaring checkout.
    ALL = T.let({ AGENT.name => AGENT, ORCHESTRATOR.name => ORCHESTRATOR }.freeze, T::Hash[String, RunnerRole])

    class << self
      extend T::Sig

      # The role `--labels <set>` aliases: the orchestrator for exactly its
      # label; nil for any other set, which is a build host's.
      #
      # @param labels [Array<String>]
      # @return [Dev::RunnerRole, nil]
      sig { params(labels: T::Array[String]).returns(T.nilable(RunnerRole)) }
      def for_labels(labels)
        labels == [ORCHESTRATOR_LABEL] ? ORCHESTRATOR : nil
      end

      # The warning register prints for an alias: what was resolved, and
      # the register run that replaces it.
      #
      # @param role [Dev::RunnerRole] AGENT or ORCHESTRATOR
      # @param flag [String] the flag or label set the operator typed
      # @return [String]
      sig { params(role: RunnerRole, flag: String).returns(String) }
      def warning(role, flag:)
        "#{flag} is an alias for the #{role.name} role ai-flow's dev.yml declares, pinned at @main; it goes away next " \
          "release — re-register from an ai-flow checkout: dev runner register --org --role #{role.name}"
      end
    end
  end
end
