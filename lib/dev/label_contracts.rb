# typed: strict
# frozen_string_literal: true

require "etc"

require "dev/agent_bootstrap"
require "dev/agent_bootstrap/darwin"
require "dev/agent_bootstrap/linux"
require "dev/platform"
require "dev/runner_group_contract"
require "dev/runner_user"

module Dev
  # The label doctrine's enforcement half (plans#26): a capability label is
  # not just routing metadata — it names an obligation the host must satisfy.
  # `dev runner register` converges the (possibly empty) requirements of
  # every label being advertised before it enrolls; the registry lives here
  # so future labels slot in without touching register itself.
  #
  # Two kinds of contract exist. Host-side, the agent capability labels
  # (`ai-build`, `ai-learn`) make the box an agent host and require the
  # agent host bootstrap — one contract, an adapter per platform
  # (AgentBootstrap::Darwin, AgentBootstrap::Linux), chosen here, the
  # composition root (plans#59). Org-side, an ai-flow label obliges a runner
  # group pinned to ai-flow's workflows — which group depends on what the
  # slots are for (dev#495): the agent labels oblige the `ai-flow` group,
  # whose selected repos are each repo's build concurrency on the host
  # (AI_FLOW_GROUP, dev#470); `ai-orchestrator` obliges its own group,
  # open to every repo (ORCHESTRATOR_GROUP) — the thin pool `/build
  # --split`'s orchestrator runs on has nothing to gate, and a plan in any
  # adopter may need one. A set carrying both is refused: one enrollment,
  # one group. A bare label (e.g. the gamebox's target-host label) requires
  # nothing — and so does `ai-orchestrator` host-side (no bootstrap).
  class LabelContracts
    extend T::Sig

    # The capability labels whose contract is the agent host bootstrap.
    AGENT_CAPABILITY_LABELS = T.let(%w[ai-build ai-learn].freeze, T::Array[String])

    # The agent host's label set — one label per slash command, routed by
    # ai-flow's reusable workflow (`runner="ai-${word}"`). ai-flow defines
    # the vocabulary (its README "Adoption checklist" names this list as
    # the contract); this is dev's documented mirror — a cross-repo literal
    # duplicated knowingly, like the agent user/group names — behind
    # `dev runner register --org --ai-flow` (the agent host enrolls with
    # this set; a partitioned topology passes --labels instead).
    AI_FLOW_AGENT_LABELS = T.let(%w[ai-ask ai-edit ai-split ai-build ai-learn].freeze, T::Array[String])

    # The orchestrator pool's label (plans#53): the one ai-flow label that
    # is a host capability rather than a command. `/build --split`'s
    # orchestrator posts child `/build`s and polls their outcome for the
    # plan's whole critical path — API calls and sleep, hours long — so it
    # runs on an always-on thin host with many cheap slots, never on an
    # agent slot (one child of parallelism lost, dies with the laptop) nor
    # on the hosted lane (bills build-shaped time). Deliberately outside
    # AI_FLOW_AGENT_LABELS: `--ai-flow` must not make an agent host an
    # orchestrator; `--labels ai-orchestrator --slots N` enrolls the pool.
    ORCHESTRATOR_LABEL = T.let("ai-orchestrator", String)

    # The full ai-flow vocabulary: every label ai-flow's workflow may
    # demand, and so every label whose org enrollment belongs in the
    # ai-flow runner group.
    AI_FLOW_LABELS = T.let((AI_FLOW_AGENT_LABELS + [ORCHESTRATOR_LABEL]).freeze, T::Array[String])

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

    # The orchestrator pool's group (dev#495): dev's, pinned to the same
    # workflows, open to every repo in the org. Not the `ai-flow` group:
    # that group's selection is a repo's *build* concurrency on the host
    # (dev#470 keeps cellbound-3d out of it on purpose), and the pool's
    # visibility must be the opposite — any adopter's `/build --split`
    # lands its orchestrator here, so a selection would only be a list to
    # forget a new adopter from. The pin keeps a fork's YAML off the box.
    ORCHESTRATOR_GROUP = T.let(
      RunnerGroupContract.new(name: "ai-orchestrator", workflows: AI_FLOW_WORKFLOWS, visibility: "all"),
      RunnerGroupContract,
    )

    # The agent host obligation: the host-singular bootstrap, the agent's
    # own container engine when the served repo builds in one (a Mac's
    # colima; a Linux host refuses — its image-built agent runs inside the
    # project's container, plans#61), and the post-enrollment
    # service/workdir setup.
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
      # @raise [AgentBootstrap::Linux::NoAgentEngineError] a container repo on a Linux host
      sig { params(container: T::Boolean, cpus: T.nilable(Integer), memory_gib: T.nilable(Integer), disk_gib: T.nilable(Integer)).void }
      def converge!(container: false, cpus: nil, memory_gib: nil, disk_gib: nil)
        @bootstrap.converge!
        @bootstrap.ensure_agent_engine!(cpus: cpus, memory_gib: memory_gib, disk_gib: disk_gib) if container
      end

      # Converge the post-enrollment requirements (needs the enrolled runner
      # dir and which of the host's slots it is).
      #
      # @param runner_dir [String]
      # @param slot [Integer] 1-based
      # @return [void]
      sig { params(runner_dir: String, slot: Integer).void }
      def after_enroll!(runner_dir:, slot:)
        @bootstrap.after_enroll!(runner_dir: runner_dir, slot: slot)
      end
    end

    class << self
      extend T::Sig

      # The contracts carried by an advertised label set.
      #
      # @param labels [String] comma-separated labels (config.sh shape)
      # @param agent_user [String, nil] run-as user override (default ai-agent)
      # @param runner_user [String, nil] the enrolling user whose service
      #   spawns the agent — the Linux host rule's runner user (RunnerUser);
      #   nil for the platform's default (the operator on a Mac)
      # @param bootstrap [Dev::AgentBootstrap, nil] injectable for tests
      # @param ui [Ui] where the host's bootstrap speaks (register's terminal)
      # @return [Array<AgentHostContract>]
      # @raise [AgentBootstrap::UnsupportedPlatformError] on a host no adapter converges
      sig do
        params(
          labels: String,
          agent_user: T.nilable(String),
          runner_user: T.nilable(String),
          bootstrap: T.nilable(Dev::AgentBootstrap),
          ui: Ui,
        ).returns(T::Array[AgentHostContract])
      end
      def for(labels, agent_user: nil, runner_user: nil, bootstrap: nil, ui: NoUi.new)
        return [] unless agent_host?(labels)

        resolved = bootstrap || agent_bootstrap(agent_user: agent_user || AgentBootstrap::DEFAULT_AGENT_USER, runner_user: runner_user, ui: ui)
        [AgentHostContract.new(bootstrap: resolved)]
      end

      # The agent host bootstrap for this host: the Darwin adapter on a Mac
      # (the operator is the runner user), the Linux adapter on a Linux dev
      # host (dev#310's runner user is). `dev runner status` builds its
      # inspector over the same object, so register and status read one
      # set of facts.
      #
      # @param agent_user [String] the run-as user
      # @param runner_user [String, nil] the enrolling user; nil for the
      #   platform's default
      # @param executor [#run, #quiet?, #capture] the admin CLI seam
      # @param ui [Ui] where the bootstrap speaks; the plain tier for a
      #   read-only build (`dev runner status`)
      # @param host_os [String] "darwin" / "linux" / "windows" (injectable for tests)
      # @return [Dev::AgentBootstrap]
      # @raise [AgentBootstrap::UnsupportedPlatformError] on a host no adapter converges
      sig do
        params(
          agent_user: String,
          runner_user: T.nilable(String),
          executor: T.untyped,
          ui: Ui,
          host_os: String,
        ).returns(AgentBootstrap)
      end
      def agent_bootstrap(agent_user: AgentBootstrap::DEFAULT_AGENT_USER, runner_user: nil,
                          executor: AgentBootstrap::Executor.new, ui: NoUi.new, host_os: Platform.os)
        case host_os
        when "darwin"
          AgentBootstrap::Darwin.new(agent_user: agent_user, executor: executor, ui: ui,
            runner_user: runner_user || T.must(Etc.getpwuid(Process.uid)).name)
        when "linux"
          AgentBootstrap::Linux.new(agent_user: agent_user, executor: executor, ui: ui,
            runner_user: runner_user || RunnerUser::DEFAULT_NAME)
        else
          raise AgentBootstrap::UnsupportedPlatformError,
            "the agent host bootstrap converges a Mac or a Linux dev host (plans#26, plans#59); " \
            "agent-capability labels cannot be served by a #{host_os} host."
        end
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
      # the ai-flow group for an agent label (`--ai-flow` or a `--labels`
      # subset of the agent vocabulary), the orchestrator group for
      # `ai-orchestrator`; nil for a bare label set, whose group is the
      # operator's to name (`--group`) or config.sh's Default.
      #
      # @param labels [String] comma-separated labels (config.sh shape)
      # @return [Dev::RunnerGroupContract, nil]
      # @raise [ArgumentError] a set carrying both an agent label and the orchestrator label
      sig { params(labels: String).returns(T.nilable(RunnerGroupContract)) }
      def group_for(labels)
        advertised = labels.split(",").map(&:strip)
        agent = advertised & AI_FLOW_AGENT_LABELS
        orchestrator = advertised.include?(ORCHESTRATOR_LABEL)
        if orchestrator && !agent.empty?
          raise ArgumentError,
            "#{ORCHESTRATOR_LABEL} sits in its own runner group ('#{ORCHESTRATOR_GROUP.name}', open to every repo) and #{agent.join(",")} " \
              "in '#{AI_FLOW_GROUP.name}' — one enrollment, one group: enroll the orchestrator pool separately " \
              "(--org --labels #{ORCHESTRATOR_LABEL} --slots N)"
        end
        return ORCHESTRATOR_GROUP if orchestrator

        agent.empty? ? nil : AI_FLOW_GROUP
      end
    end
  end
end
