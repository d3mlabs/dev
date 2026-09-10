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
  # `ai-learn`) require the agent posture bootstrap. A bare label (e.g. the
  # gamebox's target-host label) requires nothing.
  class LabelContracts
    extend T::Sig

    # The capability labels whose contract is the agent posture.
    AGENT_CAPABILITY_LABELS = T.let(%w[ai-build ai-learn].freeze, T::Array[String])

    # The agent posture obligation: the host-singular bootstrap, the agent's
    # own container engine when the served repo builds in one, and the
    # post-enrollment service/workdir posture.
    class AgentPostureContract
      extend T::Sig

      # @param bootstrap [Dev::AgentBootstrap]
      sig { params(bootstrap: Dev::AgentBootstrap).void }
      def initialize(bootstrap:)
        @bootstrap = bootstrap
      end

      # Converge the pre-enrollment posture.
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

      # Converge the post-enrollment posture (needs the enrolled runner dir).
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
      # @return [Array<AgentPostureContract>]
      sig do
        params(
          labels: String,
          agent_user: T.nilable(String),
          bootstrap: T.nilable(Dev::AgentBootstrap),
        ).returns(T::Array[AgentPostureContract])
      end
      def for(labels, agent_user: nil, bootstrap: nil)
        advertised = labels.split(",").map(&:strip)
        return [] unless advertised.intersect?(AGENT_CAPABILITY_LABELS)

        resolved = bootstrap ||
          (agent_user ? AgentBootstrap.new(agent_user: agent_user) : AgentBootstrap.new)
        [AgentPostureContract.new(bootstrap: resolved)]
      end
    end
  end
end
