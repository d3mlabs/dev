# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/runner_discovery"
require "dev/runner_family"
require "dev/runner_group_contract"
require "dev/runner_registry"
require "dev/runner_role"

transform!(RSpock::AST::Transformation)
class Dev::RunnerFamilyTest < Minitest::Test
  AGENT_LABELS = %w[ai-ask ai-edit ai-split ai-build ai-learn].freeze
  PINS = ["d3mlabs/ai-flow/.github/workflows/ai-commands.yml@refs/tags/v2"].freeze
  AGENT = Dev::RunnerRole.declared(
    name: "agent", labels: AGENT_LABELS, group: Dev::RunnerGroupContract.new(name: "ai-flow", workflows: PINS), job_identity: "ai-agent",
  )
  ORCHESTRATOR = Dev::RunnerRole.declared(
    name: "orchestrator", labels: ["ai-orchestrator"],
    group: Dev::RunnerGroupContract.new(name: "ai-orchestrator", workflows: PINS, visibility: Dev::RunnerGroupContract::ALL),
  )
  DECLARED = { "agent" => AGENT, "orchestrator" => ORCHESTRATOR }.freeze

  # --- a slot's role ------------------------------------------------------------

  test "a listed slot's role is read from its pool and labels among the roles declared at hand — #{labels.inspect} in #{pool} → #{role}" do
    Expect
    slot(name: "box", labels: labels, pool: pool).role(DECLARED).name == role

    Where
    labels              | pool              | role
    AGENT_LABELS        | "ai-flow"         | "agent"
    ["ai-build"]        | "ai-flow"         | "agent"
    AGENT_LABELS        | "Default"         | "agent"
    ["ai-orchestrator"] | "ai-orchestrator" | "orchestrator"
    ["cellbound-3d"]    | "Default"         | "build-host"
    ["ue"]              | "ue-hosted"       | "ue-hosted"
  end

  test "a slot GitHub has lost is told by its record's pool — #{pool} → #{role}" do
    Given
    lost = slot(name: "box", labels: nil, pool: pool)

    Expect
    lost.lost?
    !lost.listed?
    lost.role(DECLARED).name == role

    Where
    pool              | role
    "ai-flow"         | "agent"
    "ai-orchestrator" | "orchestrator"
    "Default"         | "build-host"
    "ue-hosted"       | "ue-hosted"
  end

  test "with no declaration at hand, a slot in a declared role's pool is known by the pool alone" do
    Given
    pooled = slot(name: "box-agent", labels: AGENT_LABELS, pool: "ai-flow").role({})

    Expect
    pooled.pooled?
    pooled.name == "ai-flow"
    pooled.labels == AGENT_LABELS
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

  test "slots group into one family per (scope, role), roles by name with the build host last, then by scope, slot 1 first within" do
    Given "three roles across two scopes, listed out of order"
    slots = [
      slot(name: "box-agent-2", labels: AGENT_LABELS, scope: "d3mlabs", pool: "ai-flow"),
      slot(name: "box", labels: ["snappy"], scope: "JPDuchesne/snappy"),
      slot(name: "box-orchestrator", labels: ["ai-orchestrator"], scope: "d3mlabs", pool: "ai-orchestrator"),
      slot(name: "box-agent", labels: AGENT_LABELS, scope: "d3mlabs", pool: "ai-flow"),
      slot(name: "box", labels: ["cellbound-3d"], scope: "d3mlabs/cellbound-3d"),
    ]

    When
    families = Dev::RunnerFamily.of(slots, declared: DECLARED)

    Then
    families.map { |family| [family.role.name, family.scope, family.slots.map { |slot| slot.enrollment.name }] } == [
      ["agent", "d3mlabs", ["box-agent", "box-agent-2"]],
      ["orchestrator", "d3mlabs", ["box-orchestrator"]],
      ["build-host", "JPDuchesne/snappy", ["box"]],
      ["build-host", "d3mlabs/cellbound-3d", ["box"]],
    ]
  end

  test "a family's role is its first listed slot's, not a lost slot's" do
    Given "slot 1 lost, slot 2 listed"
    slots = [
      slot(name: "box-agent", labels: nil, pool: "ai-flow"),
      slot(name: "box-agent-2", labels: AGENT_LABELS, pool: "ai-flow"),
    ]

    When
    family = Dev::RunnerFamily.of(slots, declared: DECLARED).fetch(0)

    Then
    family.role == AGENT
    family.first_listed.enrollment.name == "box-agent-2"
  end

  test "a family with no listed slot takes its role from the pool and has no first listed slot" do
    When
    family = Dev::RunnerFamily.of([slot(name: "box-agent", labels: nil, pool: "ai-flow")], declared: DECLARED).fetch(0)

    Then
    family.role == AGENT
    family.first_listed.nil?
    family.query_error.nil?
  end

  test "without declarations, families form by pool: one pooled family per group, the build host last" do
    Given
    slots = [
      slot(name: "box", labels: ["cellbound-3d"], scope: "d3mlabs/cellbound-3d"),
      slot(name: "box-agent", labels: AGENT_LABELS, scope: "d3mlabs", pool: "ai-flow"),
    ]

    When
    families = Dev::RunnerFamily.of(slots)

    Then
    families.map { |family| [family.role.name, family.role.pooled?] } == [["ai-flow", true], ["build-host", false]]
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
