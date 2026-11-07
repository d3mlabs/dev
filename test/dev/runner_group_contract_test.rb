# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/runner_group_contract"

transform!(RSpock::AST::Transformation)
class Dev::RunnerGroupContractTest < Minitest::Test
  PINS = %w[d3mlabs/ai-flow/.github/workflows/ai-commands.yml@refs/heads/main d3mlabs/ai-flow/.github/workflows/origin-firing.yml@refs/heads/main].freeze

  class << self
    # Class-level so Where tables can build groups.
    def group(visibility: "selected", restricted: true, workflows: PINS, allows_public: false)
      Dev::RunnerRegistry::Group.new(id: 7, name: "ai-flow", visibility: visibility, allows_public_repositories: allows_public,
        restricted_to_workflows: restricted, selected_workflows: workflows)
    end
  end

  def group(**kwargs)
    self.class.group(**kwargs)
  end

  test "a contract with pins is owned; one without names a human's group" do
    Expect
    Dev::RunnerGroupContract.new(name: "ai-flow", workflows: PINS).owned?
    !Dev::RunnerGroupContract.new(name: "ue-hosted").owned?
  end

  test "an owned contract is satisfied by a selected group pinned to exactly its workflows, in any order" do
    Expect
    Dev::RunnerGroupContract.new(name: "ai-flow", workflows: PINS).drift(group) == []
    Dev::RunnerGroupContract.new(name: "ai-flow", workflows: PINS.reverse).drift(group) == []
  end

  test "an owned contract reports #{what} as drift" do
    Expect
    Dev::RunnerGroupContract.new(name: "ai-flow", workflows: PINS).drift(drifted) == lines

    Where
    what                        | drifted                                              | lines
    "an unrestricted group"     | group(restricted: false, workflows: [])              | ["not restricted to workflows"]
    "a group pinned elsewhere"  | group(workflows: [PINS.first])                       | ["pinned to #{PINS.first}"]
    "a group restricted to nothing (an incomplete PATCH's leftover)" | group(workflows: []) | ["pinned to nothing — no workflow may use it"]
    "a group open to all repos" | group(visibility: "all") | ["visibility is 'all', not 'selected'"]
    "both"                      | group(visibility: "all", restricted: false, workflows: []) | ["visibility is 'all', not 'selected'", "not restricted to workflows"]
  end

  test "a named contract never drifts: what a human's group pins is theirs" do
    Expect
    Dev::RunnerGroupContract.new(name: "ue-hosted").drift(group(visibility: "all", restricted: false, workflows: [])) == []
  end

  test "contracts are values" do
    Expect
    Dev::RunnerGroupContract.new(name: "a", workflows: PINS) == Dev::RunnerGroupContract.new(name: "a", workflows: PINS)
    Dev::RunnerGroupContract.new(name: "a", workflows: PINS).hash == Dev::RunnerGroupContract.new(name: "a", workflows: PINS).hash
    Dev::RunnerGroupContract.new(name: "a") != Dev::RunnerGroupContract.new(name: "b")
  end
end
