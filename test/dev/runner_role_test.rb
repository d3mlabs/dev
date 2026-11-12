# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/label_contracts"
require "dev/runner_role"

transform!(RSpock::AST::Transformation)
class Dev::RunnerRoleTest < Minitest::Test
  AGENT_LABELS = Dev::LabelContracts::AI_FLOW_AGENT_LABELS
  PINS = Dev::LabelContracts::AI_FLOW_WORKFLOWS

  # --- the builtins -------------------------------------------------------

  test "the agent role carries the five agent labels and the pinned ai-flow group, so it is org-scoped" do
    Given
    role = Dev::RunnerRole::AGENT

    Expect
    role.name == "agent"
    role.labels == AGENT_LABELS
    role.group == Dev::LabelContracts::AI_FLOW_GROUP
    role.builtin?
    role.org_scoped?
    role.pool_name == "ai-flow"
  end

  test "the orchestrator role carries the one orchestrator label and its open pinned group" do
    Given
    role = Dev::RunnerRole::ORCHESTRATOR

    Expect
    role.name == "orchestrator"
    role.labels == ["ai-orchestrator"]
    role.group == Dev::LabelContracts::ORCHESTRATOR_GROUP
    role.org_scoped?
    role.pool_name == "ai-orchestrator"
  end

  test "a build host carries the labels it is given, no group, and is not org-scoped by itself" do
    Given
    role = Dev::RunnerRole.build_host(labels: ["cellbound-3d"])

    Expect
    role.name == "build-host"
    role.labels == ["cellbound-3d"]
    role.group.nil?
    role.builtin?
    !role.org_scoped?
    role.pool_name == "Default"
  end

  test "a build host in a human's group names that group as its pool but owns no pin" do
    Given
    role = Dev::RunnerRole.build_host(labels: ["ue-engine"], group: Dev::RunnerGroupContract.new(name: "ue-hosted"))

    Expect
    role.pool_name == "ue-hosted"
    !role.org_scoped?
  end

  test "a user role is declared with a name and labels and is never builtin" do
    Given
    role = Dev::RunnerRole.user(name: "ue-farm", labels: %w[ue gpu])

    Expect
    role.name == "ue-farm"
    role.labels == %w[ue gpu]
    !role.builtin?
    !role.org_scoped?
    role.group.nil?
  end

  test "a user role may not take a builtin's name nor an ai-flow label — those roles are code's" do
    Expect
    assert_raises(Dev::RunnerRole::DeclarationError) { Dev::RunnerRole.user(name: "agent", labels: ["x"]) }.is_a?(StandardError)
    assert_raises(Dev::RunnerRole::DeclarationError) { Dev::RunnerRole.user(name: "farm", labels: ["ai-build"]) }.is_a?(StandardError)
    assert_raises(Dev::RunnerRole::DeclarationError) { Dev::RunnerRole.user(name: "farm", labels: []) }.is_a?(StandardError)
  end

  test "builtin lookup by name — #{name.inspect}" do
    Expect
    Dev::RunnerRole.builtin(name) == role

    Where
    name            | role
    "agent"         | Dev::RunnerRole::AGENT
    "orchestrator"  | Dev::RunnerRole::ORCHESTRATOR
    "ue-farm"       | nil
    "build-host"    | nil
  end

  # --- labels → role (the sugar flags) -------------------------------------

  test "from a label set: #{labels.inspect} → #{expected}" do
    Expect
    Dev::RunnerRole.for_labels(labels).name == expected

    Where
    labels                               | expected
    AGENT_LABELS                         | "agent"
    ["ai-build"]                         | "agent"
    ["ai-orchestrator"]                  | "orchestrator"
    ["cellbound-3d"]                     | "build-host"
    %w[ue-engine x64]                    | "build-host"
  end

  test "an agent subset keeps the labels it was given — a partitioned topology — under the agent role" do
    Expect
    Dev::RunnerRole.for_labels(["ai-build", "ai-learn"]).labels == ["ai-build", "ai-learn"]
    Dev::RunnerRole.for_labels(["ai-build", "ai-learn"]).group == Dev::LabelContracts::AI_FLOW_GROUP
  end

  test "a set mixing the orchestrator label with an agent label is refused — one enrollment, one group" do
    Expect
    assert_raises(ArgumentError) { Dev::RunnerRole.for_labels(["ai-build", "ai-orchestrator"]) }.message.include?("one enrollment, one group")
  end

  # --- naming --------------------------------------------------------------

  test "slot base: a grouped or user role is <host>-<role>; a build host is the host alone — #{role.name}" do
    Expect
    role.slot_base("JPSFF") == base

    Where
    role                                                 | base
    Dev::RunnerRole::AGENT                               | "JPSFF-agent"
    Dev::RunnerRole::ORCHESTRATOR                        | "JPSFF-orchestrator"
    Dev::RunnerRole.user(name: "ue-farm", labels: ["ue"]) | "JPSFF-ue-farm"
    Dev::RunnerRole.build_host(labels: ["cellbound-3d"])  | "JPSFF"
  end

  test "dir suffix: the role's name, or for a build host its first label sanitized — a path, never identity" do
    Expect
    Dev::RunnerRole::AGENT.dir_suffix == "agent"
    Dev::RunnerRole::ORCHESTRATOR.dir_suffix == "orchestrator"
    Dev::RunnerRole.user(name: "ue-farm", labels: ["ue"]).dir_suffix == "ue-farm"
    Dev::RunnerRole.build_host(labels: ["ue 5.8/editor", "macos"]).dir_suffix == "ue-5.8-editor"
    Dev::RunnerRole.build_host(labels: ["cellbound-3d"]).dir_suffix == "cellbound-3d"
  end

  # --- family membership: what a role claims --------------------------------

  test "#{role.name} claims a runner advertising #{labels.inspect}: #{claims}" do
    Expect
    role.claims?(labels) == claims

    Where
    role                                                | labels                 | claims
    Dev::RunnerRole::AGENT                              | AGENT_LABELS           | true
    Dev::RunnerRole::AGENT                              | ["ai-ask"]             | true
    Dev::RunnerRole::AGENT                              | ["cellbound3d"]        | true
    Dev::RunnerRole::AGENT                              | ["ai-orchestrator"]    | false
    Dev::RunnerRole::ORCHESTRATOR                       | ["ai-orchestrator"]    | true
    Dev::RunnerRole::ORCHESTRATOR                       | ["ai-build"]           | false
    Dev::RunnerRole::ORCHESTRATOR                       | ["old"]                | true
    Dev::RunnerRole.build_host(labels: ["snappy"])      | ["snappy"]             | true
    Dev::RunnerRole.build_host(labels: ["snappy"])      | ["ai-build"]           | false
    Dev::RunnerRole.user(name: "farm", labels: ["ue"])  | ["ai-orchestrator"]    | false
  end

  # --- reach: who may land a job on a slot of this role ----------------------

  test "the agent's expected reach is the target repo, through the pinned workflows, on its labels" do
    Given
    target = Dev::Reach::Target.new(repo: "d3mlabs/snappy", public: false)

    When
    reach = Dev::RunnerRole::AGENT.expected_reach(target)

    Then
    reach.repos == Set["d3mlabs/snappy"]
    reach.workflows == Set.new(PINS)
    reach.labels == Set.new(AGENT_LABELS)
    reach.pinned?
  end

  test "the orchestrator's expected reach is every repo, through the pinned workflows" do
    When
    reach = Dev::RunnerRole::ORCHESTRATOR.expected_reach(Dev::Reach::Target.new(repo: "d3mlabs/snappy", public: true))

    Then
    reach.repos == Dev::Reach::ALL
    reach.workflows == Set.new(PINS)
    reach.pinned?
  end

  test "a build host's expected reach is its repo through any workflow — the one gate that cannot drift, since there is no group" do
    When
    reach = Dev::RunnerRole.build_host(labels: ["snappy"]).expected_reach(Dev::Reach::Target.new(repo: "d3mlabs/snappy", public: false))

    Then
    reach.repos == Set["d3mlabs/snappy"]
    reach.workflows == Dev::Reach::ANY
    !reach.pinned?
  end

  test "any workflow against a public repo is plans#5 Gap 1 reopened: the reach is refused, naming the hole" do
    Given
    role = Dev::RunnerRole.build_host(labels: ["snappy"])

    When
    error = assert_raises(Dev::Reach::ExposedError) { role.expected_reach(Dev::Reach::Target.new(repo: "d3mlabs/dev", public: true)) }

    Then
    error.message.include?("d3mlabs/dev is public")
    error.message.include?("plans#5")
  end
end
