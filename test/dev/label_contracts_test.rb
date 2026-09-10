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

  test "agent capability labels carry the agent posture contract" do
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
    bootstrap.expects(:ensure_agent_engine!).with(cpus: 8, memory_gib: 24).once
    contract.converge!(container: true, cpus: 8, memory_gib: 24)

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

  test "after_enroll! passes the runner dir through" do
    Given "a contract over a mocked bootstrap"
    bootstrap = typed_mock(Dev::AgentBootstrap)
    contract = Dev::LabelContracts.for("ai-learn", bootstrap: bootstrap).fetch(0)

    When "converging the post-enrollment posture"
    bootstrap.expects(:after_enroll!).with(runner_dir: "/tmp/runner").once
    contract.after_enroll!(runner_dir: "/tmp/runner")

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
