# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/runner_role"
require "dev/runner_setup_config"

transform!(RSpock::AST::Transformation)
class Dev::RunnerSetupConfigTest < Minitest::Test
  UE = Dev::RunnerRole.build_host(labels: ["ue-engine"])

  test "optional fields default to nil" do
    When "creating a config with only a role"
    config = Dev::RunnerSetupConfig.new(role: UE)

    Then "and config.sh is not told to --replace: a held name is never taken over unless register says it is this family's own (dev#565)"
    config.role == UE
    config.dir.nil?
    config.name.nil?
    config.version.nil?
    config.replace == false
  end

  test "labels and group derive from the role — the config declares the role, config.sh gets the labels" do
    Expect
    Dev::RunnerSetupConfig.new(role: Dev::RunnerRole::AGENT).labels == Dev::LabelContracts::AI_FLOW_AGENT_LABELS.join(",")
    Dev::RunnerSetupConfig.new(role: Dev::RunnerRole::AGENT).group == "ai-flow"
    Dev::RunnerSetupConfig.new(role: Dev::RunnerRole::ORCHESTRATOR).group == "ai-orchestrator"
    Dev::RunnerSetupConfig.new(role: UE).labels == "ue-engine"
    Dev::RunnerSetupConfig.new(role: UE).group.nil?
    Dev::RunnerSetupConfig.new(role: Dev::RunnerRole.build_host(labels: %w[ue-engine x64], group: Dev::RunnerGroupContract.new(name: "ue-hosted"))).group == "ue-hosted"
  end

  test "equality compares all fields" do
    Given "two identical configs"
    a = Dev::RunnerSetupConfig.new(role: UE, dir: "~/r", name: "box", version: "2.335.1")
    b = Dev::RunnerSetupConfig.new(role: UE, dir: "~/r", name: "box", version: "2.335.1")

    Expect
    a == b
    a.eql?(b)
    a.hash == b.hash
  end

  test "inequality when a field differs" do
    Given "two configs with different roles, and two differing only in whether config.sh may --replace"
    a = Dev::RunnerSetupConfig.new(role: UE)
    b = Dev::RunnerSetupConfig.new(role: Dev::RunnerRole.build_host(labels: ["cellbound3d"]))
    replacing = Dev::RunnerSetupConfig.new(role: UE, replace: true)

    Expect
    a != b
    a.hash != b.hash
    a != replacing
  end
end
