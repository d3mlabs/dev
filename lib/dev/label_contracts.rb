# typed: strict
# frozen_string_literal: true

require "dev/agent_bootstrap"
require "dev/runner_group_contract"

module Dev
  # The label doctrine's enforcement half (plans#26): a capability label is
  # not just routing metadata — it names an obligation the host must satisfy.
  # `dev runner register` converges the (possibly empty) requirements of
  # every label being advertised before it enrolls; the registry lives here
  # so future labels slot in without touching register itself.
  #
  # Two contracts exist: the agent capability labels (`ai-build`,
  # `ai-learn`) make the box an agent host and require the agent host
  # bootstrap (host-side); any ai-flow label obliges, at org scope, the
  # ai-flow runner group pinned to ai-flow's workflows (org-side, see
  # AI_FLOW_GROUP). A bare label (e.g. the gamebox's target-host label)
  # requires nothing.
  class LabelContracts
    extend T::Sig

    # The capability labels whose contract is the agent host bootstrap.
    AGENT_CAPABILITY_LABELS = T.let(%w[ai-build ai-learn].freeze, T::Array[String])

    # The full ai-flow label vocabulary — one label per slash command,
    # routed by ai-flow's reusable workflow (`runner="ai-${word}"`). ai-flow
    # defines the vocabulary (its README "Adoption checklist" names this
    # list as the contract); this is dev's documented mirror — a cross-repo
    # literal duplicated knowingly, like the agent user/group names —
    # behind `dev runner register --org --ai-flow` (the agent host enrolls
    # with the full set; a partitioned topology passes --labels instead).
    AI_FLOW_LABELS = T.let(%w[ai-ask ai-edit ai-split ai-build ai-learn].freeze, T::Array[String])

    # The two ai-flow workflows that may land jobs on an ai-flow runner —
    # the reusable command workflow and the origin-firing check (both run
    # on these labels; a single pin starved the checks, plans#5 H3). Jobs
    # defined in a reusable workflow are checked against the reusable
    # workflow's path and ref, so this pins the runners to exactly these
    # files at ai-flow's main, whoever calls them. Another cross-repo
    # literal duplicated knowingly: the paths are ai-flow's, the ref is
    # where every caller workflow points (`@main`).
    AI_FLOW_WORKFLOWS = T.let(
      %w[
        d3mlabs/ai-flow/.github/workflows/ai-commands.yml@refs/heads/main
        d3mlabs/ai-flow/.github/workflows/origin-firing.yml@refs/heads/main
      ].freeze,
      T::Array[String],
    )

    # The org-side half of the ai-flow contract (dev#470): every runner
    # carrying an ai-flow label sits in the `ai-flow` runner group, which
    # dev owns — created when missing, pinned to AI_FLOW_WORKFLOWS, its
    # selected repositories the checkouts register ran in. Nothing about
    # it is typed by a human, so nothing about it can be forgotten; the
    # console can drift it, and the next register heals it.
    AI_FLOW_GROUP = T.let(RunnerGroupContract.new(name: "ai-flow", workflows: AI_FLOW_WORKFLOWS), RunnerGroupContract)

    # The agent host obligation: the host-singular bootstrap, the agent's
    # own container engine when the served repo builds in one, and the
    # post-enrollment service/workdir setup.
    class AgentHostContract
      extend T::Sig

      # @param bootstrap [Dev::AgentBootstrap]
      sig { params(bootstrap: Dev::AgentBootstrap).void }
      def initialize(bootstrap:)
        @bootstrap = bootstrap
      end

      # Converge the pre-enrollment requirements.
      #
      # @param container [Boolean] whether the served repo's lock pins an image
      # @param cpus [Integer, nil] engine VM sizing hint
      # @param memory_gib [Integer, nil] engine VM sizing hint
      # @param disk_gib [Integer, nil] engine VM disk hint (grow-only)
      # @return [void]
      sig { params(container: T::Boolean, cpus: T.nilable(Integer), memory_gib: T.nilable(Integer), disk_gib: T.nilable(Integer)).void }
      def converge!(container: false, cpus: nil, memory_gib: nil, disk_gib: nil)
        @bootstrap.converge!
        @bootstrap.ensure_agent_engine!(cpus: cpus, memory_gib: memory_gib, disk_gib: disk_gib) if container
      end

      # Converge the post-enrollment requirements (needs the enrolled runner dir).
      #
      # @param runner_dir [String]
      # @return [void]
      sig { params(runner_dir: String).void }
      def after_enroll!(runner_dir:)
        @bootstrap.after_enroll!(runner_dir: runner_dir)
      end
    end

    class << self
      extend T::Sig

      # The contracts carried by an advertised label set.
      #
      # @param labels [String] comma-separated labels (config.sh shape)
      # @param agent_user [String, nil] run-as user override (default ai-agent)
      # @param bootstrap [Dev::AgentBootstrap, nil] injectable for tests
      # @return [Array<AgentHostContract>]
      sig do
        params(
          labels: String,
          agent_user: T.nilable(String),
          bootstrap: T.nilable(Dev::AgentBootstrap),
        ).returns(T::Array[AgentHostContract])
      end
      def for(labels, agent_user: nil, bootstrap: nil)
        return [] unless agent_host?(labels)

        resolved = bootstrap ||
          (agent_user ? AgentBootstrap.new(agent_user: agent_user) : AgentBootstrap.new)
        [AgentHostContract.new(bootstrap: resolved)]
      end

      # Whether an advertised label set makes this box an agent host.
      #
      # @param labels [String] comma-separated labels (config.sh shape)
      # @return [Boolean]
      sig { params(labels: String).returns(T::Boolean) }
      def agent_host?(labels)
        labels.split(",").map(&:strip).intersect?(AGENT_CAPABILITY_LABELS)
      end

      # The runner group an advertised label set obliges at org scope:
      # the ai-flow group for any ai-flow label (`--ai-flow` or a
      # `--labels` subset of the vocabulary); nil for a bare label set,
      # whose group is the operator's to name (`--group`) or config.sh's
      # Default.
      #
      # @param labels [String] comma-separated labels (config.sh shape)
      # @return [Dev::RunnerGroupContract, nil]
      sig { params(labels: String).returns(T.nilable(RunnerGroupContract)) }
      def group_for(labels)
        labels.split(",").map(&:strip).intersect?(AI_FLOW_LABELS) ? AI_FLOW_GROUP : nil
      end
    end
  end
end
