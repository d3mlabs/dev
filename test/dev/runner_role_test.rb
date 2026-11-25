# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/runner_role"

transform!(RSpock::AST::Transformation)
class Dev::RunnerRoleTest < Minitest::Test
  AGENT_LABELS = %w[ai-ask ai-edit ai-split ai-build ai-learn].freeze
  # The same set as GitHub may list it: order is not identity.
  SHUFFLED_LABELS = AGENT_LABELS.reverse.freeze
  PINS = %w[
    d3mlabs/ai-flow/.github/workflows/ai-commands.yml@refs/tags/v2
    d3mlabs/ai-flow/.github/workflows/origin-firing.yml@refs/tags/v2
  ].freeze
  AGENT_GROUP = Dev::RunnerGroupContract.new(name: "ai-flow", workflows: PINS)
  OPEN_GROUP = Dev::RunnerGroupContract.new(name: "ai-orchestrator", workflows: PINS, visibility: Dev::RunnerGroupContract::ALL)

  # A role as ai-flow's dev.yml would declare it, bound to its repo.
  AGENT = Dev::RunnerRole.declared(name: "agent", labels: AGENT_LABELS, group: AGENT_GROUP, job_identity: "ai-agent")
  ORCHESTRATOR = Dev::RunnerRole.declared(name: "orchestrator", labels: ["ai-orchestrator"], group: OPEN_GROUP)
  FARM = Dev::RunnerRole.declared(name: "ue-farm", labels: %w[ue gpu])

  # --- the build host -------------------------------------------------------

  test "a build host carries the labels it is given, no group, no job identity, and is not org-scoped by itself" do
    Given
    role = Dev::RunnerRole.build_host(labels: ["cellbound-3d"])

    Expect
    role.name == "build-host"
    role.labels == ["cellbound-3d"]
    role.group.nil?
    role.job_identity.nil?
    role.build_host?
    !role.declared?
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

  # --- declared roles ----------------------------------------------------------

  test "a declared role with a pinned group and a job identity is org-scoped and named for its group's pool" do
    Expect
    AGENT.name == "agent"
    AGENT.labels == AGENT_LABELS
    AGENT.group == AGENT_GROUP
    AGENT.job_identity == "ai-agent"
    AGENT.declared?
    !AGENT.build_host?
    AGENT.org_scoped?
    AGENT.pool_name == "ai-flow"
  end

  test "a declared role without a group is its repo's: no pool, no job identity, never org-scoped" do
    Expect
    FARM.name == "ue-farm"
    FARM.labels == %w[ue gpu]
    FARM.declared?
    !FARM.org_scoped?
    FARM.group.nil?
    FARM.job_identity.nil?
    FARM.pool_name == "Default"
  end

  test "a declared role may not take the builtin's name, declare no labels, or sit in an unpinned group" do
    Expect
    assert_raises(Dev::RunnerRole::DeclarationError) { Dev::RunnerRole.declared(name: "build-host", labels: ["x"]) }.is_a?(StandardError)
    assert_raises(Dev::RunnerRole::DeclarationError) { Dev::RunnerRole.declared(name: "farm", labels: []) }.is_a?(StandardError)
    assert_raises(Dev::RunnerRole::DeclarationError) do
      Dev::RunnerRole.declared(name: "farm", labels: ["ue"], group: Dev::RunnerGroupContract.new(name: "ue-hosted"))
    end.message.include?("pins no workflows")
  end

  # --- a declaration bound to its project ------------------------------------

  test "a declaration binds its workflow paths to the project's repo at its series tag, v<major>" do
    Given
    declaration = Dev::RunnerRole::Declaration.new(
      name: "agent",
      labels: AGENT_LABELS,
      group: "ai-flow",
      workflows: %w[.github/workflows/ai-commands.yml .github/workflows/origin-firing.yml],
      job_identity: "ai-agent",
    )

    When
    role = declaration.bind(repo: "d3mlabs/ai-flow", version: "2.4.1")

    Then
    role == AGENT
    role.group.workflows == PINS
    role.group.visibility == "selected"
  end

  test "a declaration's group visibility is carried into the bound group" do
    Given
    declaration = Dev::RunnerRole::Declaration.new(
      name: "orchestrator",
      labels: ["ai-orchestrator"],
      group: "ai-orchestrator",
      visibility: "all",
      workflows: %w[.github/workflows/ai-commands.yml .github/workflows/origin-firing.yml],
    )

    Expect
    declaration.bind(repo: "d3mlabs/ai-flow", version: "2.0.0") == ORCHESTRATOR
  end

  test "a declaration without workflows binds to a role in no group, whatever the version — nothing to pin" do
    Given
    declaration = Dev::RunnerRole::Declaration.new(name: "ue-farm", labels: %w[ue gpu])

    Expect
    declaration.bind(repo: "d3mlabs/cellbound-3d", version: nil) == FARM
    declaration.bind(repo: "d3mlabs/cellbound-3d", version: "not-a-version") == FARM
  end

  test "a declaration pinning workflows refuses a project with #{description}" do
    Given
    declaration = Dev::RunnerRole::Declaration.new(name: "agent", labels: ["ai-build"], group: "ai-flow", workflows: [".github/workflows/x.yml"])

    When
    error = assert_raises(Dev::RunnerRole::DeclarationError) { declaration.bind(repo: "d3mlabs/ai-flow", version: version) }

    Then
    error.message.include?(fragment)

    Where
    description          | version   | fragment
    "no VERSION"         | nil       | "keeps no VERSION"
    "a pre-release"      | "2.0.0rc" | "is not major.minor.patch"
  end

  # --- the role a slot plays ---------------------------------------------------

  test "for a slot: #{description}" do
    Expect
    Dev::RunnerRole.for_slot(pool: pool, labels: labels, declared: declared) == expected

    Where
    description                                               | pool              | labels              | declared             | expected
    "a declared role's pool names the role"                   | "ai-flow"         | ["ai-build"]        | { "agent" => AGENT } | AGENT
    "a lost slot in a declared role's pool is still its"      | "ai-flow"         | nil                 | { "agent" => AGENT } | AGENT
    "a declared role at its repo is known by its labels"      | "Default"         | AGENT_LABELS        | { "agent" => AGENT } | AGENT
    "labels in another order still name the role"             | "Default"         | SHUFFLED_LABELS     | { "agent" => AGENT } | AGENT
    "a slot sharing a label with a role is its (drift shows)" | "Default"         | %w[ai-build gpu]    | { "agent" => AGENT } | AGENT
    "labels no declared role claims are a build host's"       | "Default"         | ["gpu"]             | { "agent" => AGENT } | Dev::RunnerRole.build_host(labels: ["gpu"])
    "Default with nothing declared is a build host"           | "Default"         | ["cellbound-3d"]    | {}                   | Dev::RunnerRole.build_host(labels: ["cellbound-3d"])
    "a lost build host has no labels left"                    | "Default"         | nil                 | {}                   | Dev::RunnerRole.build_host(labels: [])
    "a pool no declaration names is a pooled role"            | "ai-orchestrator" | ["ai-orchestrator"] | { "agent" => AGENT } | Dev::RunnerRole.pooled(pool: "ai-orchestrator", labels: ["ai-orchestrator"])
    "a lost slot in an unknown pool is pooled without labels" | "ue-hosted"       | nil                 | {}                   | Dev::RunnerRole.pooled(pool: "ue-hosted", labels: [])
  end

  test "a pooled role is named for its pool, sits in an unpinned group, and judges nothing" do
    Given
    role = Dev::RunnerRole.pooled(pool: "ai-orchestrator", labels: ["ai-orchestrator"])

    Expect
    role.pooled?
    role.name == "ai-orchestrator"
    role.pool_name == "ai-orchestrator"
    !role.org_scoped?
    role.job_identity.nil?
  end

  # --- naming --------------------------------------------------------------

  test "slot base: a declared role is <host>-<role>; a build host is the host alone — #{role.name}" do
    Expect
    role.slot_base("JPSFF") == base

    Where
    role                                                | base
    AGENT                                               | "JPSFF-agent"
    ORCHESTRATOR                                        | "JPSFF-orchestrator"
    FARM                                                | "JPSFF-ue-farm"
    Dev::RunnerRole.build_host(labels: ["cellbound-3d"]) | "JPSFF"
  end

  test "dir suffix: the role's name, or for a build host its first label sanitized — a path, never identity" do
    Expect
    AGENT.dir_suffix == "agent"
    FARM.dir_suffix == "ue-farm"
    Dev::RunnerRole.build_host(labels: ["ue 5.8/editor", "macos"]).dir_suffix == "ue-5.8-editor"
    Dev::RunnerRole.build_host(labels: ["cellbound-3d"]).dir_suffix == "cellbound-3d"
    Dev::RunnerRole.build_host(labels: []).dir_suffix == "default"
  end

  # --- family membership: what a role claims --------------------------------

  test "#{role.name} claims a runner advertising #{labels.inspect}: #{claims}" do
    Expect
    role.claims?(labels) == claims

    Where
    role                                           | labels                          | claims
    AGENT                                          | AGENT_LABELS                    | true
    AGENT                                          | ["ai-ask"]                      | true
    AGENT                                          | ["cellbound3d"]                 | false
    AGENT                                          | ["ai-orchestrator"]             | false
    AGENT                                          | ["ai-build", "ai-orchestrator"] | true
    ORCHESTRATOR                                   | ["ai-orchestrator"]             | true
    ORCHESTRATOR                                   | ["ai-build"]                    | false
    Dev::RunnerRole.build_host(labels: ["snappy"]) | ["snappy"]                      | true
    Dev::RunnerRole.build_host(labels: ["snappy"]) | ["ai-build"]                    | false
    FARM                                           | ["ai-orchestrator"]             | false
  end

  # --- reach: who may land a job on a slot of this role ----------------------

  test "a selected-group role's expected reach at its org is the target repo, through the pinned workflows, on its labels" do
    Given
    target = Dev::Reach::Target.new(repo: "d3mlabs/snappy", public: false, org_scoped: true)

    When
    reach = AGENT.expected_reach(target)

    Then
    reach.repos == Set["d3mlabs/snappy"]
    reach.workflows == Set.new(PINS)
    reach.labels == Set.new(AGENT_LABELS)
    reach.pinned?
  end

  test "an open-group role's expected reach is every repo, through the pinned workflows" do
    When
    reach = ORCHESTRATOR.expected_reach(Dev::Reach::Target.new(repo: "d3mlabs/snappy", public: true, org_scoped: true))

    Then
    reach.repos == Dev::Reach::ALL
    reach.workflows == Set.new(PINS)
    reach.pinned?
  end

  test "a build host's expected reach is its repo through any workflow — the one gate that cannot drift, since there is no group" do
    When
    reach = Dev::RunnerRole.build_host(labels: ["snappy"]).expected_reach(Dev::Reach::Target.new(repo: "d3mlabs/snappy", public: false, org_scoped: false))

    Then
    reach.repos == Set["d3mlabs/snappy"]
    reach.workflows == Dev::Reach::ANY
    !reach.pinned?
  end

  test "a grouped role registered at a private repo reaches that repo through any workflow: scope fixes the first clause, the role keeps its labels" do
    Given
    target = Dev::Reach::Target.new(repo: "d3mlabs/cellbound-3d", public: false, org_scoped: false)

    When
    reach = AGENT.expected_reach(target)

    Then
    reach.repos == Set["d3mlabs/cellbound-3d"]
    reach.workflows == Dev::Reach::ANY
    reach.labels == Set.new(AGENT_LABELS)
    !reach.pinned?
  end

  test "a grouped role registered at a public repo is refused like a build host: no group pins what may land on it" do
    When
    error = assert_raises(Dev::Reach::ExposedError) { AGENT.expected_reach(Dev::Reach::Target.new(repo: "d3mlabs/dev", public: true, org_scoped: false)) }

    Then
    error.message.include?("d3mlabs/dev is public and its agent runners")
  end

  test "a build host for a public repo is refused: any workflow could land on it, and the message says so" do
    Given
    role = Dev::RunnerRole.build_host(labels: ["snappy"])

    When
    error = assert_raises(Dev::Reach::ExposedError) { role.expected_reach(Dev::Reach::Target.new(repo: "d3mlabs/dev", public: true, org_scoped: false)) }

    Then
    error.message.include?("d3mlabs/dev is public")
    error.message.include?("YAML could land on this host")
  end

  # --- identity ---------------------------------------------------------------

  test "two roles are equal when their name, labels, group, job identity and kind are" do
    Expect
    AGENT == Dev::RunnerRole.declared(name: "agent", labels: AGENT_LABELS, group: AGENT_GROUP, job_identity: "ai-agent")
    AGENT != Dev::RunnerRole.declared(name: "agent", labels: AGENT_LABELS, group: AGENT_GROUP)
    Dev::RunnerRole.build_host(labels: ["x"]) != Dev::RunnerRole.pooled(pool: "Default", labels: ["x"])
  end
end
