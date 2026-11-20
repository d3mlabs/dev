# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/runner_role_aliases"

transform!(RSpock::AST::Transformation)
class Dev::RunnerRoleAliasesTest < Minitest::Test
  test "the agent alias is ai-flow's agent role as it was builtin: five labels, the ai-flow group pinned at @main, jobs as ai-agent" do
    Given
    role = Dev::RunnerRoleAliases::AGENT

    Expect
    role.name == "agent"
    role.labels == %w[ai-ask ai-edit ai-split ai-build ai-learn]
    role.group.name == "ai-flow"
    role.group.workflows == Dev::RunnerRoleAliases::WORKFLOWS_AT_MAIN
    role.group.workflows.all? { |pin| pin.end_with?("@refs/heads/main") }
    !role.group.open?
    role.job_identity == "ai-agent"
    role.declared?
    role.org_scoped?
  end

  test "the orchestrator alias is its one label in an open group pinned at @main, no job identity" do
    Given
    role = Dev::RunnerRoleAliases::ORCHESTRATOR

    Expect
    role.name == "orchestrator"
    role.labels == ["ai-orchestrator"]
    role.group.name == "ai-orchestrator"
    role.group.open?
    role.group.workflows == Dev::RunnerRoleAliases::WORKFLOWS_AT_MAIN
    role.job_identity.nil?
  end

  test "ALL lists both by name — what status reads a host's slots against until they are re-registered" do
    Expect
    Dev::RunnerRoleAliases::ALL == { "agent" => Dev::RunnerRoleAliases::AGENT, "orchestrator" => Dev::RunnerRoleAliases::ORCHESTRATOR }
  end

  test "--labels ai-orchestrator alone aliases the orchestrator" do
    Expect
    Dev::RunnerRoleAliases.for_labels(["ai-orchestrator"]) == Dev::RunnerRoleAliases::ORCHESTRATOR
  end

  test "--labels #{labels.inspect} aliases nothing: a build host's set" do
    Expect
    Dev::RunnerRoleAliases.for_labels(labels).nil?

    Where
    labels                           | _
    ["ai-build"]                     | nil
    ["ai-build", "ai-orchestrator"]  | nil
    ["cellbound-3d"]                 | nil
  end

  test "the warning names what was typed, the role it stands for, the @main pin, and the register run that replaces it" do
    When
    warning = Dev::RunnerRoleAliases.warning(Dev::RunnerRoleAliases::AGENT, flag: "--ai-flow")

    Then
    warning.start_with?("--ai-flow is an alias for the agent role ai-flow's dev.yml declares, pinned at @main")
    warning.include?("goes away next release")
    warning.end_with?("dev runner register --org --role agent")
  end
end
