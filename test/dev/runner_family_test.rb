# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/label_contracts"
require "dev/runner_discovery"
require "dev/runner_family"
require "dev/runner_registry"

transform!(RSpock::AST::Transformation)
class Dev::RunnerFamilyTest < Minitest::Test
  AGENT_LABELS = Dev::LabelContracts::AI_FLOW_AGENT_LABELS

  # --- a slot's role ------------------------------------------------------------

  test "a listed slot's role is read from its GitHub labels — #{labels.inspect} → #{role}" do
    Expect
    slot(name: "box", labels: labels).role.name == role

    Where
    labels              | role
    AGENT_LABELS        | "agent"
    ["ai-orchestrator"] | "orchestrator"
    ["cellbound-3d"]    | "build-host"
  end

  test "a slot GitHub has lost is told by its record's pool — #{pool} → #{role}" do
    Given
    lost = slot(name: "box", labels: nil, pool: pool)

    Expect
    lost.lost?
    !lost.listed?
    lost.role.name == role

    Where
    pool              | role
    "ai-flow"         | "agent"
    "ai-orchestrator" | "orchestrator"
    "Default"         | "build-host"
  end

  test "a slot whose labels claim two roles is a build host with those labels — shown, not hidden" do
    Given
    mixed = slot(name: "box", labels: ["ai-build", "ai-orchestrator"])

    Expect
    mixed.role.name == "build-host"
    mixed.role.labels == ["ai-build", "ai-orchestrator"]
  end

  test "a slot GitHub could not be asked about is neither listed nor lost" do
    Given
    unasked = slot(name: "box", labels: nil, query_error: "network is unreachable")

    Expect
    !unasked.listed?
    !unasked.lost?
    unasked.query_error == "network is unreachable"
  end

  test "a slot's number is its name's suffix, 1 for the bare base — #{name}" do
    Expect
    slot(name: name, labels: ["x"]).number == number

    Where
    name            | number
    "box"           | 1
    "box-2"         | 2
    "box-agent"     | 1
    "box-agent-10"  | 10
  end

  # --- grouping ----------------------------------------------------------------

  test "slots group into one family per (scope, role), in builtin role order then by scope, slot 1 first within" do
    Given "three roles across two scopes, listed out of order"
    slots = [
      slot(name: "box-agent-2", labels: AGENT_LABELS, scope: "d3mlabs"),
      slot(name: "box", labels: ["snappy"], scope: "JPDuchesne/snappy"),
      slot(name: "box-orchestrator", labels: ["ai-orchestrator"], scope: "d3mlabs"),
      slot(name: "box-agent", labels: AGENT_LABELS, scope: "d3mlabs"),
      slot(name: "box", labels: ["cellbound-3d"], scope: "d3mlabs/cellbound-3d"),
    ]

    When
    families = Dev::RunnerFamily.of(slots)

    Then
    families.map { |family| [family.role.name, family.scope, family.slots.map { |slot| slot.enrollment.name }] } == [
      ["agent", "d3mlabs", ["box-agent", "box-agent-2"]],
      ["orchestrator", "d3mlabs", ["box-orchestrator"]],
      ["build-host", "JPDuchesne/snappy", ["box"]],
      ["build-host", "d3mlabs/cellbound-3d", ["box"]],
    ]
  end

  test "a family's role is its first listed slot's — the agent subset it advertises — not a lost slot's full set" do
    Given "slot 1 lost, slot 2 listed with a partition of the agent labels"
    slots = [
      slot(name: "box-agent", labels: nil, pool: "ai-flow"),
      slot(name: "box-agent-2", labels: ["ai-build", "ai-learn"]),
    ]

    When
    family = Dev::RunnerFamily.of(slots).fetch(0)

    Then
    family.role.name == "agent"
    family.role.labels == ["ai-build", "ai-learn"]
    family.first_listed.enrollment.name == "box-agent-2"
  end

  test "a family with no listed slot takes its role from the pool and has no first listed slot" do
    When
    family = Dev::RunnerFamily.of([slot(name: "box-agent", labels: nil, pool: "ai-flow")]).fetch(0)

    Then
    family.role.name == "agent"
    family.first_listed.nil?
    family.query_error.nil?
  end

  test "scope: an org family is org-scoped and a repo family's org is the repo's owner" do
    Expect
    Dev::RunnerFamily.of([slot(name: "box", labels: ["x"], scope: "d3mlabs")]).fetch(0).org_scoped?
    Dev::RunnerFamily.of([slot(name: "box", labels: ["x"], scope: "d3mlabs")]).fetch(0).org == "d3mlabs"
    !Dev::RunnerFamily.of([slot(name: "box", labels: ["x"], scope: "d3mlabs/dev")]).fetch(0).org_scoped?
    Dev::RunnerFamily.of([slot(name: "box", labels: ["x"], scope: "d3mlabs/dev")]).fetch(0).org == "d3mlabs"
  end

  test "a family's query error is the first of its slots'" do
    Given
    slots = [
      slot(name: "box", labels: nil, query_error: "offline"),
      slot(name: "box-2", labels: nil, query_error: "offline"),
    ]

    Expect
    Dev::RunnerFamily.of(slots).fetch(0).query_error == "offline"
  end

  private

  # A slot: an enrollment record and GitHub's answer — a runner carrying
  # `labels`, or nil (lost, or `query_error` when GitHub could not be asked).
  def slot(name:, labels:, scope: "d3mlabs", pool: "Default", query_error: nil)
    enrollment = Dev::RunnerDiscovery::Enrollment.new(
      dir: "/home/runner/actions-runner-#{name}", scope: scope, name: name, agent_id: 1,
      service_installed: true, display_dir: "~/actions-runner-#{name}", owner: "runner", pool: pool,
    )
    runner = labels && Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: labels, status: "online")
    Dev::RunnerFamily::Slot.new(enrollment: enrollment, runner: runner, query_error: query_error)
  end
end
