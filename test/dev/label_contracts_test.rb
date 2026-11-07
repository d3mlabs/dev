# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/label_contracts"

transform!(RSpock::AST::Transformation)
class Dev::LabelContractsTest < Minitest::Test
  include SorbetHelper

  test "bare labels carry no contract" do
    Expect "the gamebox-style registration converges nothing"
    Dev::LabelContracts.for("gamebox").empty?
    Dev::LabelContracts.for("ue-engine,x64").empty?
  end

  test "any ai-flow label obliges the ai-flow runner group, owned by dev and pinned to ai-flow's two workflows; a bare set obliges none (dev#470)" do
    Expect
    Dev::LabelContracts.group_for(Dev::LabelContracts::AI_FLOW_LABELS.join(",")) == Dev::LabelContracts::AI_FLOW_GROUP
    Dev::LabelContracts.group_for("macos,ai-build") == Dev::LabelContracts::AI_FLOW_GROUP
    Dev::LabelContracts.group_for("ue-engine,x64").nil?
    Dev::LabelContracts::AI_FLOW_GROUP.name == "ai-flow"
    Dev::LabelContracts::AI_FLOW_GROUP.owned?
    Dev::LabelContracts::AI_FLOW_GROUP.workflows == [
      "d3mlabs/ai-flow/.github/workflows/ai-commands.yml@refs/heads/main",
      "d3mlabs/ai-flow/.github/workflows/origin-firing.yml@refs/heads/main",
    ]
  end

  test "ai-orchestrator is in the ai-flow vocabulary — same group — but is no agent host and is not in --ai-flow's set (plans#53)" do
    Expect "it joins the ai-flow group like any ai-flow label; a thin host converges nothing (no agent bootstrap); an agent host does not become an orchestrator by default"
    Dev::LabelContracts.group_for("ai-orchestrator") == Dev::LabelContracts::AI_FLOW_GROUP
    Dev::LabelContracts::AI_FLOW_LABELS.include?("ai-orchestrator")
    Dev::LabelContracts.for("ai-orchestrator").empty?
    !Dev::LabelContracts.agent_host?("ai-orchestrator")
    !Dev::LabelContracts::AI_FLOW_AGENT_LABELS.include?("ai-orchestrator")
    Dev::LabelContracts::AI_FLOW_AGENT_LABELS == %w[ai-ask ai-edit ai-split ai-build ai-learn]
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

  test "the run-as user override reaches the bootstrap construction" do
    Given "an agent-user override"
    bootstrap = typed_mock(Dev::AgentBootstrap)
    Dev::AgentBootstrap.expects(:new).with(agent_user: "ci").returns(bootstrap)

    When "resolving contracts"
    contracts = Dev::LabelContracts.for("ai-build", agent_user: "ci")

    Then
    contracts.length == 1
  end
end
