# typed: strict
# frozen_string_literal: true

require "dev/agent_bootstrap"

module Dev
  # The label doctrine's enforcement half (plans#26): a capability label is
  # not just routing metadata — it names an obligation the host must satisfy.
  # `dev runner register` converges the (possibly empty) requirements of
  # every label being advertised before it enrolls; the registry lives here
  # so future labels slot in without touching register itself.
  #
  # Today one contract exists: the agent capability labels (`ai-build`,
  # `ai-learn`) make the box an agent host and require the agent host
  # bootstrap. A bare label (e.g. the gamebox's target-host label) requires
  # nothing.
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
      # @param container [Boolean] whether the served repo declares build.container
      # @param cpus [Integer, nil] engine VM sizing hint
      # @param memory_gib [Integer, nil] engine VM sizing hint
      # @return [void]
      sig { params(container: T::Boolean, cpus: T.nilable(Integer), memory_gib: T.nilable(Integer)).void }
      def converge!(container: false, cpus: nil, memory_gib: nil)
        @bootstrap.converge!
        @bootstrap.ensure_agent_engine!(cpus: cpus, memory_gib: memory_gib) if container
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
    end
  end
end
