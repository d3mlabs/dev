# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/reach"
require "dev/reach_fact"
require "dev/runner_registry"
require "dev/runner_role"

transform!(RSpock::AST::Transformation)
class Dev::ReachFactTest < Minitest::Test
  PINS = Set.new(%w[
    d3mlabs/ai-flow/.github/workflows/ai-commands.yml@refs/tags/v2
    d3mlabs/ai-flow/.github/workflows/origin-firing.yml@refs/tags/v2
  ])
  AGENT_LABELS = Set.new(%w[ai-ask ai-edit ai-split ai-build ai-learn])

  class << self
    def group(name:, visibility: "selected", pinned: true)
      Dev::RunnerRegistry::Group.new(id: 7, name: name, visibility: visibility, allows_public_repositories: false,
        restricted_to_workflows: pinned, selected_workflows: pinned ? PINS.to_a : [])
    end

    def placement(**options)
      Dev::ReachFact::GroupPlacement.new(group: group(**options))
    end
  end

  AGENT_EXPECTED = Dev::Reach.new(repos: Set["d3mlabs/dev"], workflows: PINS, labels: AGENT_LABELS)
  ORCHESTRATOR_EXPECTED = Dev::Reach.new(repos: Dev::Reach::ALL, workflows: PINS, labels: Set["ai-orchestrator"])

  # --- the comparison, clause by clause --------------------------------------

  test "GitHub's reach matching the role's clause for clause is ok with no drift" do
    Given
    observed = Dev::Reach.new(repos: Set["d3mlabs/dev", "d3mlabs/plans"], workflows: PINS, labels: AGENT_LABELS)
    fact = Dev::ReachFact.compare(expected: AGENT_EXPECTED, observed: observed, fixed_by: self.class.placement(name: "ai-flow"))

    Expect
    fact.ok?
    fact.drift == []
    !fact.exposed?
  end

  test "the repos clause compares by shape — #{what}" do
    Given
    observed = Dev::Reach.new(repos: repos, workflows: PINS, labels: expected.labels)
    fact = Dev::ReachFact.compare(expected: expected, observed: observed, fixed_by: self.class.placement(name: "g"))

    Expect
    fact.drift == drift

    Where
    what                                                    | expected              | repos                                     | drift
    "a selection expecting one: which repos is not a drift" | AGENT_EXPECTED        | Set["d3mlabs/plans", "d3mlabs/knowledge"] | []
    "every repo where the role expects a selection"         | AGENT_EXPECTED        | Dev::Reach::ALL                           | [:repos]
    "no repo at all where the role expects a selection"     | AGENT_EXPECTED        | Set[]                                     | [:repos]
    "every repo where the role expects every repo"          | ORCHESTRATOR_EXPECTED | Dev::Reach::ALL                           | []
    "a selection where the role expects every repo"         | ORCHESTRATOR_EXPECTED | Set["d3mlabs/dev"]                        | [:repos]
  end

  test "the workflows and labels clauses compare as sets — #{what}" do
    Given
    observed = Dev::Reach.new(repos: Set["d3mlabs/dev"], workflows: workflows, labels: labels)
    fact = Dev::ReachFact.compare(expected: AGENT_EXPECTED, observed: observed, fixed_by: self.class.placement(name: "ai-flow"))

    Expect
    fact.drift == drift
    fact.ok? == drift.empty?

    Where
    what                               | workflows                                                    | labels                               | drift
    "the pin, in another order"        | Set.new(PINS.to_a.reverse)                                   | AGENT_LABELS                         | []
    "no pin where the role pins"       | Dev::Reach::ANY                                              | AGENT_LABELS                         | [:workflows]
    "restricted to nothing"            | Set[]                                                        | AGENT_LABELS                         | [:workflows]
    "another pin"                      | Set["d3mlabs/other/.github/workflows/x.yml@refs/heads/main"] | AGENT_LABELS                         | [:workflows]
    "a label the role does not oblige" | PINS                                                         | Set.new(AGENT_LABELS.to_a + ["gpu"]) | [:labels]
    "both at once, in clause order"    | Dev::Reach::ANY                                              | Set["ai-ask"]                        | [:workflows, :labels]
  end

  # --- the role's refusal ------------------------------------------------------

  test "a role that refused the target is a fact with no expected reach and never ok" do
    Given
    observed = Dev::Reach.new(repos: Set["d3mlabs/dev"], workflows: Dev::Reach::ANY, labels: Set["dev"])
    fact = Dev::ReachFact.exposed(exposure: "d3mlabs/dev is public", observed: observed,
      fixed_by: Dev::ReachFact::RepoRegistration.new(repo: "d3mlabs/dev"))

    Expect
    fact.exposed?
    !fact.ok?
    fact.drift == []
    fact.expected.nil?
    fact.exposure == "d3mlabs/dev is public"
  end

  # --- the provenance's evidence ------------------------------------------------

  test "a group placement names the group, its visibility and its pin — #{what}" do
    Expect
    self.class.placement(name: name, visibility: visibility, pinned: pinned).evidence == evidence

    Where
    what                 | name      | visibility | pinned | evidence
    "pinned, selected"   | "ai-flow" | "selected" | true   | "slots sit in org group `ai-flow` (visibility selected, restricted to 2 workflows)"
    "Default, open"      | "Default" | "all"      | false  | "slots sit in org group `Default` (visibility all, not restricted to workflows)"
  end

  test "a repo registration names the repo and that only an org registration can change it" do
    Expect
    Dev::ReachFact::RepoRegistration.new(repo: "d3mlabs/cellbound-3d").evidence ==
      "reach is fixed by the repo registration at d3mlabs/cellbound-3d (its own workflows, no pin) — only an org registration in a group can widen or pin it"
  end
end
