# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/label_contracts"
require "etc"
require "support/recording_ui"

transform!(RSpock::AST::Transformation)
class Dev::LabelContractsTest < Minitest::Test
  include SorbetHelper

  test "bare labels carry no contract" do
    Expect "the gamebox-style registration converges nothing"
    Dev::LabelContracts.for("gamebox").empty?
    Dev::LabelContracts.for("ue-engine,x64").empty?
  end

  test "any agent label obliges the ai-flow runner group, owned by dev and pinned to ai-flow's two workflows; a bare set obliges none (dev#470)" do
    Expect
    Dev::LabelContracts.group_for(Dev::LabelContracts::AI_FLOW_AGENT_LABELS.join(",")) == Dev::LabelContracts::AI_FLOW_GROUP
    Dev::LabelContracts.group_for("macos,ai-build") == Dev::LabelContracts::AI_FLOW_GROUP
    Dev::LabelContracts.group_for("ue-engine,x64").nil?
    Dev::LabelContracts::AI_FLOW_GROUP.name == "ai-flow"
    Dev::LabelContracts::AI_FLOW_GROUP.owned?
    Dev::LabelContracts::AI_FLOW_GROUP.workflows == [
      "d3mlabs/ai-flow/.github/workflows/ai-commands.yml@refs/heads/main",
      "d3mlabs/ai-flow/.github/workflows/origin-firing.yml@refs/heads/main",
    ]
  end

  test "ai-orchestrator is in the ai-flow vocabulary but obliges its own group, open to every repo; no agent host, not in --ai-flow's set (plans#53, dev#495)" do
    Expect "the pool's group is dev's, pinned to the same workflows, visibility all — nothing to gate on a thin host; the build slots' group selection stays a repo's concurrency"
    Dev::LabelContracts.group_for("ai-orchestrator") == Dev::LabelContracts::ORCHESTRATOR_GROUP
    Dev::LabelContracts.group_for("linux,ai-orchestrator") == Dev::LabelContracts::ORCHESTRATOR_GROUP
    Dev::LabelContracts::ORCHESTRATOR_GROUP.name == "ai-orchestrator"
    Dev::LabelContracts::ORCHESTRATOR_GROUP.owned?
    Dev::LabelContracts::ORCHESTRATOR_GROUP.visibility == "all"
    Dev::LabelContracts::ORCHESTRATOR_GROUP.workflows == Dev::LabelContracts::AI_FLOW_GROUP.workflows
    Dev::LabelContracts::AI_FLOW_GROUP.visibility == "selected"
    Dev::LabelContracts::AI_FLOW_LABELS.include?("ai-orchestrator")
    Dev::LabelContracts.for("ai-orchestrator").empty?
    !Dev::LabelContracts.agent_host?("ai-orchestrator")
    !Dev::LabelContracts::AI_FLOW_AGENT_LABELS.include?("ai-orchestrator")
    Dev::LabelContracts::AI_FLOW_AGENT_LABELS == %w[ai-ask ai-edit ai-split ai-build ai-learn]
  end

  test "a set carrying an agent label and the orchestrator label is refused: one enrollment, one group" do
    When
    Dev::LabelContracts.group_for("ai-build,ai-orchestrator")

    Then
    error = raises ArgumentError
    error.message.include?("ai-orchestrator")
    error.message.include?("ai-build")
    error.message.include?("one enrollment, one group")
  end

  test "agent capability labels carry the agent host contract" do
    Expect
    Dev::LabelContracts.for("ai-build", bootstrap: typed_mock(Dev::AgentBootstrap)).length == 1
    Dev::LabelContracts.for("macos,ai-learn", bootstrap: typed_mock(Dev::AgentBootstrap)).length == 1
  end

  test "the contract converges the bootstrap, adding the engine leg only for container repos" do
    Given "a contract over a mocked bootstrap"
    bootstrap = typed_mock(Dev::AgentBootstrap)
    contract = Dev::LabelContracts.for("ai-build", bootstrap: bootstrap).fetch(0)

    When "converging for a container repo with a sizing hint"
    bootstrap.expects(:converge!).once
    bootstrap.expects(:ensure_agent_engine!).with(cpus: 8, memory_gib: 24, disk_gib: 250).once
    contract.converge!(container: true, cpus: 8, memory_gib: 24, disk_gib: 250)

    Then
    true
  end

  test "the contract skips the engine leg for container-free repos" do
    Given "a contract over a mocked bootstrap"
    bootstrap = typed_mock(Dev::AgentBootstrap)
    contract = Dev::LabelContracts.for("ai-build", bootstrap: bootstrap).fetch(0)

    When "converging without a container"
    bootstrap.expects(:converge!).once
    bootstrap.expects(:ensure_agent_engine!).never
    contract.converge!(container: false)

    Then
    true
  end

  test "after_enroll! passes the runner dir and slot through" do
    Given "a contract over a mocked bootstrap"
    bootstrap = typed_mock(Dev::AgentBootstrap)
    contract = Dev::LabelContracts.for("ai-learn", bootstrap: bootstrap).fetch(0)

    When "converging the post-enrollment steps"
    bootstrap.expects(:after_enroll!).with(runner_dir: "/tmp/runner", slot: 2).once
    contract.after_enroll!(runner_dir: "/tmp/runner", slot: 2)

    Then
    true
  end

  test "the run-as user and the runner user reach the host's bootstrap construction" do
    Given "an agent-user override and the host rule's runner user"
    bootstrap = typed_mock(Dev::AgentBootstrap)
    ui = RecordingUi.new
    Dev::LabelContracts.expects(:agent_bootstrap).with(agent_user: "ci", runner_user: "runner", ui: ui).returns(bootstrap)

    When "resolving contracts"
    contracts = Dev::LabelContracts.for("ai-build", agent_user: "ci", runner_user: "runner", ui: ui)

    Then
    contracts.length == 1
  end

  test "without overrides the bootstrap is built for the default agent user and the platform's runner user" do
    Given
    bootstrap = typed_mock(Dev::AgentBootstrap)
    Dev::LabelContracts.expects(:agent_bootstrap).with { |agent_user:, runner_user:, ui:| agent_user == "ai-agent" && runner_user.nil? && ui.is_a?(Dev::NoUi) }.returns(bootstrap)

    When
    contracts = Dev::LabelContracts.for("ai-build")

    Then
    contracts.length == 1
  end

  # plans#59: one contract, an adapter per platform, chosen here — the
  # composition root. The runner user is the sudoers grantor: the operator
  # on a Mac (a per-user LaunchAgent), dev#310's `runner` on Linux.
  test "the host factory picks the #{host_os} adapter with that platform's runner user" do
    Given "no deployment tap to read from the host's settings"
    Dev::TapTrust.stubs(:deployment_tap).returns(nil)

    When "building the bootstrap for the host"
    bootstrap = Dev::LabelContracts.agent_bootstrap(agent_user: "ci", host_os: host_os)

    Then
    bootstrap.is_a?(adapter)
    bootstrap.agent_user == "ci"
    bootstrap.runner_user == runner_user

    Where
    host_os  | adapter                        | runner_user
    "darwin" | Dev::AgentBootstrap::Darwin    | Etc.getpwuid(Process.uid).name
    "linux"  | Dev::AgentBootstrap::Linux     | Dev::RunnerUser::DEFAULT_NAME
  end

  test "the host factory hands the Ui to the #{host_os} adapter: the bootstrap speaks where register does" do
    Given "an adapter intercepted at construction"
    ui = RecordingUi.new
    adapter.expects(:new).once.with { |**kwargs| kwargs.fetch(:ui).equal?(ui) }.returns(typed_mock(Dev::AgentBootstrap))

    When
    Dev::LabelContracts.agent_bootstrap(host_os: host_os, ui: ui)

    Then "the expectation on the construction boundary holds"
    true

    Where
    host_os  | adapter
    "darwin" | Dev::AgentBootstrap::Darwin
    "linux"  | Dev::AgentBootstrap::Linux
  end

  test "the host factory hands an explicit runner user through" do
    Given
    Dev::TapTrust.stubs(:deployment_tap).returns(nil)

    Expect
    Dev::LabelContracts.agent_bootstrap(host_os: "linux", runner_user: "svc").runner_user == "svc"
    Dev::LabelContracts.agent_bootstrap(host_os: "darwin", runner_user: "human").runner_user == "human"
  end

  test "the host factory refuses a platform no adapter converges" do
    When
    Dev::LabelContracts.agent_bootstrap(host_os: "windows")

    Then
    error = raises Dev::AgentBootstrap::UnsupportedPlatformError
    error.message.include?("windows")
    error.message.include?("plans#59")
  end
end
