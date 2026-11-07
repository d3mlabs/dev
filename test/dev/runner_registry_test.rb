# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/runner_registry"
require "json"

transform!(RSpock::AST::Transformation)
class Dev::RunnerRegistryTest < Minitest::Test
  PINS = %w[d3mlabs/ai-flow/.github/workflows/ai-commands.yml@refs/heads/main d3mlabs/ai-flow/.github/workflows/origin-firing.yml@refs/heads/main].freeze

  # Answers capture calls from a responder and records each argv.
  class RecordingExecutor
    attr_reader :captures

    def initialize(&responder)
      @responder = responder
      @captures = []
    end

    def capture(*argv)
      @captures << argv
      @responder ? @responder.call(argv) : ["", "", true]
    end
  end

  # On the class, ahead of the tests: Where cells are evaluated there, at
  # definition.
  class << self
    # One `--jq .runners[]` output line: GitHub's runner object with
    # read-only labels (self-hosted, OS, arch) alongside the custom ones,
    # its status ("online" / "offline") and whether it is running a job.
    def runner_json(id:, name:, custom:, status: "online", busy: false)
      labels = [{ "name" => "self-hosted", "type" => "read-only" }] +
               custom.map { |l| { "name" => l, "type" => "custom" } }
      JSON.generate({ "id" => id, "name" => name, "status" => status, "busy" => busy, "labels" => labels })
    end
  end

  test "find returns the named runner's id and custom labels at an org scope" do
    Given "a gh answering with two runners, one line each"
    lines = [
      runner_json(id: 7, name: "other-box", custom: ["ue-engine"]),
      runner_json(id: 42, name: "JeanPhiippesMBP", custom: %w[ai-ask ai-build]),
    ].join("\n")
    exec = RecordingExecutor.new { [lines, "", true] }
    registry = Dev::RunnerRegistry.new(executor: exec)

    When "finding by name"
    runner = registry.find(scope: "d3mlabs", name: "JeanPhiippesMBP")

    Then "the org endpoint is paginated and the read-only labels are excluded"
    exec.captures == [["gh", "api", "--paginate", "orgs/d3mlabs/actions/runners", "--jq", ".runners[]"]]
    runner.id == 42
    runner.custom_labels == %w[ai-ask ai-build]
  end

  test "find carries GitHub's health verdict: status #{status.inspect} reads as online? == #{online}" do
    Given "a gh answering with a runner GitHub lists as #{status}"
    exec = RecordingExecutor.new { [runner_json(id: 42, name: "JPSFF", custom: ["snappy"], status: status), "", true] }
    registry = Dev::RunnerRegistry.new(executor: exec)

    When "finding"
    runner = registry.find(scope: "JPDuchesne/snappy", name: "JPSFF")

    Then "the status is GitHub's word, and online? is the one contract (busy is irrelevant)"
    runner.status == status
    runner.online? == online

    Where
    status    | online
    "online"  | true
    "offline" | false
  end

  test "find hits the repos endpoint for a repo scope" do
    Given "a gh answering with one runner"
    exec = RecordingExecutor.new { [runner_json(id: 1, name: "box", custom: ["cellbound3d"]), "", true] }
    registry = Dev::RunnerRegistry.new(executor: exec)

    When "finding at a repo scope"
    registry.find(scope: "d3mlabs/cellbound-3d", name: "box")

    Then
    exec.captures.fetch(0).fetch(3) == "repos/d3mlabs/cellbound-3d/actions/runners"
  end

  test "find is nil when no runner of that name is enrolled at the scope" do
    Given "a gh answering with unrelated runners"
    exec = RecordingExecutor.new { [runner_json(id: 7, name: "other-box", custom: []), "", true] }
    registry = Dev::RunnerRegistry.new(executor: exec)

    Expect
    registry.find(scope: "d3mlabs", name: "JeanPhiippesMBP").nil?
  end

  test "find raises when GitHub cannot be queried" do
    Given "a gh that fails (offline, auth)"
    exec = RecordingExecutor.new { ["", "connect: network is unreachable", false] }
    registry = Dev::RunnerRegistry.new(executor: exec)

    When "finding"
    registry.find(scope: "d3mlabs", name: "box")

    Then "the failure is loud, never a silent not-found"
    error = raises Dev::RunnerRegistry::QueryError
    error.message.include?("network is unreachable")
  end

  test "available answers the first online runner carrying the label: #{what}" do
    Given "a gh listing the scope's runners"
    exec = RecordingExecutor.new { [lines.join("\n"), "", true] }
    registry = Dev::RunnerRegistry.new(executor: exec)

    When "asking at the repo scope"
    runner = registry.available(scope: "d3mlabs/cellbound-3d", label: "cellbound-3d")

    Then "the repo endpoint is paginated, and the answer is GitHub's: label present, listener connected"
    exec.captures == [["gh", "api", "--paginate", "repos/d3mlabs/cellbound-3d/actions/runners", "--jq", ".runners[]"]]
    runner&.id == id

    Where
    what                                             | lines                                                                                                                              | id
    "one online runner carries it"                   | [runner_json(id: 7, name: "box", custom: ["cellbound-3d"])]                                                                        | 7
    "the label is matched case-insensitively"        | [runner_json(id: 7, name: "box", custom: ["Cellbound-3D"])]                                                                        | 7
    "an offline one carrying it is skipped"          | [runner_json(id: 7, name: "box", custom: ["cellbound-3d"], status: "offline"), runner_json(id: 8, name: "mac", custom: ["cellbound-3d"])] | 8
    "a busy one still counts"                        | [runner_json(id: 7, name: "box", custom: ["cellbound-3d"], busy: true)]                                                            | 7
    "the only one carrying it is offline"            | [runner_json(id: 7, name: "box", custom: ["cellbound-3d"], status: "offline")]                                                     | nil
    "the scope's runners carry other labels"         | [runner_json(id: 7, name: "box", custom: ["ue-engine"])]                                                                           | nil
    "nothing is enrolled at the scope"               | []                                                                                                                                 | nil
  end

  test "available never matches a read-only label: self-hosted is GitHub's, not an enrollment's" do
    Given
    exec = RecordingExecutor.new { [runner_json(id: 7, name: "box", custom: []), "", true] }
    registry = Dev::RunnerRegistry.new(executor: exec)

    Expect
    registry.available(scope: "d3mlabs/cellbound-3d", label: "self-hosted").nil?
  end

  test "available raises when GitHub cannot be queried — never a silent 'no runner'" do
    Given
    exec = RecordingExecutor.new { ["", "HTTP 401: Bad credentials", false] }
    registry = Dev::RunnerRegistry.new(executor: exec)

    When
    registry.available(scope: "d3mlabs/cellbound-3d", label: "cellbound-3d")

    Then
    error = raises Dev::RunnerRegistry::QueryError
    error.message.include?("Bad credentials")
  end

  test "Runner#carries? reads the custom labels case-insensitively, as GitHub routes them" do
    Given
    runner = Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["Cellbound-3D", "ue-engine"], status: "online")

    Expect
    runner.carries?("cellbound-3d")
    runner.carries?("UE-ENGINE")
    !runner.carries?("snappy")
  end

  test "amend! replaces the runner's custom labels in place" do
    Given "a recording gh"
    exec = RecordingExecutor.new { ["", "", true] }
    registry = Dev::RunnerRegistry.new(executor: exec)

    When "amending"
    registry.amend!(scope: "d3mlabs", runner_id: 42, labels: %w[ai-ask ai-edit ai-build ai-split ai-learn])

    Then "one PUT carries the full custom set"
    exec.captures == [[
      "gh", "api", "-X", "PUT", "orgs/d3mlabs/actions/runners/42/labels",
      "-f", "labels[]=ai-ask", "-f", "labels[]=ai-edit", "-f", "labels[]=ai-build",
      "-f", "labels[]=ai-split", "-f", "labels[]=ai-learn"
    ]]
  end

  test "amend! raises when the PUT fails" do
    Given "a gh refusing the amend"
    # A lambda (not a plain block): blocks auto-splat their single array
    # argument under RSpock's transformation.
    responder = ->(argv) { argv.include?("PUT") ? ["", "HTTP 403", false] : ["", "", true] }
    exec = RecordingExecutor.new(&responder)
    registry = Dev::RunnerRegistry.new(executor: exec)

    When "amending"
    registry.amend!(scope: "d3mlabs", runner_id: 42, labels: ["ai-ask"])

    Then
    error = raises Dev::RunnerRegistry::AmendError
    error.message.include?("HTTP 403")
  end

  # --- runner groups: who may use a runner (dev#470) -----------------------

  test "group finds an org's runner group by name, with its repository and workflow access as GitHub records them; nil when the org has none of that name" do
    Given "an org with two groups, the first pinned to two workflows and open to public repos"
    lines = [
      JSON.generate({ "id" => 1, "name" => "Default", "visibility" => "selected", "default" => true, "allows_public_repositories" => true,
                      "restricted_to_workflows" => true, "selected_workflows" => ["d3mlabs/ai-flow/.github/workflows/ai-commands.yml@refs/heads/main"] }),
      JSON.generate({ "id" => 3, "name" => "ue-hosted", "visibility" => "selected", "default" => false, "allows_public_repositories" => false,
                      "restricted_to_workflows" => false, "selected_workflows" => [] }),
    ].join("\n")
    exec = RecordingExecutor.new { [lines, "", true] }
    registry = Dev::RunnerRegistry.new(executor: exec)

    When
    default = registry.group(org: "d3mlabs", name: "Default")
    ue = registry.group(org: "d3mlabs", name: "ue-hosted")
    missing = registry.group(org: "d3mlabs", name: "agents")

    Then
    exec.captures.first == ["gh", "api", "--paginate", "orgs/d3mlabs/actions/runner-groups", "--jq", ".runner_groups[]"]
    [default&.id, default&.name, default&.visibility, default&.selected?] == [1, "Default", "selected", true]
    [default&.allows_public_repositories, default&.restricted_to_workflows] == [true, true]
    default&.selected_workflows == ["d3mlabs/ai-flow/.github/workflows/ai-commands.yml@refs/heads/main"]
    [ue&.allows_public_repositories, ue&.restricted_to_workflows, ue&.selected_workflows] == [false, false, []]
    missing.nil?
  end

  test "create_group! POSTs the group's access in one call — pins imply restricted_to_workflows — and answers GitHub's record" do
    Given
    created = JSON.generate({ "id" => 7, "name" => "ai-flow", "visibility" => "selected", "allows_public_repositories" => false,
                              "restricted_to_workflows" => true, "selected_workflows" => ["d3mlabs/ai-flow/.github/workflows/ai-commands.yml@refs/heads/main"] })
    exec = RecordingExecutor.new { [created, "", true] }

    When
    group = Dev::RunnerRegistry.new(executor: exec).create_group!(
      org: "d3mlabs", name: "ai-flow", visibility: "selected", allows_public_repositories: false,
      selected_workflows: ["d3mlabs/ai-flow/.github/workflows/ai-commands.yml@refs/heads/main"],
    )

    Then
    exec.captures == [[
      "gh", "api", "-X", "POST", "orgs/d3mlabs/actions/runner-groups", "-f", "name=ai-flow", "-f", "visibility=selected",
      "-F", "allows_public_repositories=false", "-F", "restricted_to_workflows=true",
      "-f", "selected_workflows[]=d3mlabs/ai-flow/.github/workflows/ai-commands.yml@refs/heads/main"
    ]]
    [group.id, group.name, group.restricted_to_workflows] == [7, "ai-flow", true]
  end

  test "update_group! always sends the whole pin set — GitHub's PATCH reads an omitted selected_workflows as none — and names visibility only when asked to, since naming it wipes the selected repositories (plans#5 H3)" do
    Given
    updated = JSON.generate({ "id" => 7, "name" => "ai-flow", "visibility" => "selected", "allows_public_repositories" => true,
                              "restricted_to_workflows" => true, "selected_workflows" => PINS })
    exec = RecordingExecutor.new { [updated, "", true] }
    registry = Dev::RunnerRegistry.new(executor: exec)

    When "flipping the public flag, re-pinning in place, flipping visibility, and unrestricting"
    group = registry.update_group!(org: "d3mlabs", group_id: 7, allows_public_repositories: true, selected_workflows: PINS)
    registry.update_group!(org: "d3mlabs", group_id: 7, selected_workflows: PINS)
    registry.update_group!(org: "d3mlabs", group_id: 7, visibility: "selected", selected_workflows: PINS)
    registry.update_group!(org: "d3mlabs", group_id: 7, selected_workflows: [])

    Then
    pins = PINS.flat_map { |pin| ["-f", "selected_workflows[]=#{pin}"] }
    exec.captures == [
      ["gh", "api", "-X", "PATCH", "orgs/d3mlabs/actions/runner-groups/7", "-F", "allows_public_repositories=true", "-F", "restricted_to_workflows=true", *pins],
      ["gh", "api", "-X", "PATCH", "orgs/d3mlabs/actions/runner-groups/7", "-F", "restricted_to_workflows=true", *pins],
      ["gh", "api", "-X", "PATCH", "orgs/d3mlabs/actions/runner-groups/7", "-f", "visibility=selected", "-F", "restricted_to_workflows=true", *pins],
      ["gh", "api", "-X", "PATCH", "orgs/d3mlabs/actions/runner-groups/7", "-F", "restricted_to_workflows=false"],
    ]
    group.allows_public_repositories == true
  end

  test "a group is pinned only when restricted to at least one workflow: restricted to none is a dead group, not a safe one" do
    Expect
    [restricted, workflows, pinned].then { |r, w, p| Dev::RunnerRegistry::Group.new(id: 1, name: "g", visibility: "selected", allows_public_repositories: false, restricted_to_workflows: r, selected_workflows: w).pinned? == p }

    Where
    restricted | workflows | pinned
    true       | PINS      | true
    true       | []        | false
    false      | []        | false
  end

  test "group_of answers the group listing the runner among its runners, asking group by group" do
    Given "two groups, the runner in the second"
    groups = [
      JSON.generate({ "id" => 1, "name" => "Default", "visibility" => "selected" }),
      JSON.generate({ "id" => 3, "name" => "ue-hosted", "visibility" => "selected" }),
    ].join("\n")
    responder = lambda do |argv|
      next [groups, "", true] if argv.include?("orgs/d3mlabs/actions/runner-groups")
      next ["7\n", "", true] if argv.include?("orgs/d3mlabs/actions/runner-groups/1/runners")
      next ["42\n9\n", "", true] if argv.include?("orgs/d3mlabs/actions/runner-groups/3/runners")

      ["", "", true]
    end
    registry = Dev::RunnerRegistry.new(executor: RecordingExecutor.new(&responder))

    Expect
    registry.group_of(org: "d3mlabs", runner_id: 42)&.name == "ue-hosted"
    registry.group_of(org: "d3mlabs", runner_id: 99).nil?
  end

  test "group_repositories lists a group's selection as id + full name" do
    Given
    lines = [
      JSON.generate({ "id" => 100, "name" => "dev", "full_name" => "d3mlabs/dev" }),
      JSON.generate({ "id" => 200, "name" => "cellbound-3d", "full_name" => "d3mlabs/cellbound-3d" }),
    ].join("\n")
    exec = RecordingExecutor.new { [lines, "", true] }
    registry = Dev::RunnerRegistry.new(executor: exec)

    When
    repos = registry.group_repositories(org: "d3mlabs", group_id: 1)

    Then
    exec.captures == [["gh", "api", "--paginate", "orgs/d3mlabs/actions/runner-groups/1/repositories", "--jq", ".repositories[]"]]
    repos.map(&:full_name) == ["d3mlabs/dev", "d3mlabs/cellbound-3d"]
    repos.map(&:id) == [100, 200]
  end

  test "select_group_repositories! PUTs the full selection as typed ids" do
    Given
    exec = RecordingExecutor.new { ["", "", true] }

    When
    Dev::RunnerRegistry.new(executor: exec).select_group_repositories!(org: "d3mlabs", group_id: 1, repository_ids: [100, 300])

    Then
    exec.captures == [[
      "gh", "api", "-X", "PUT", "orgs/d3mlabs/actions/runner-groups/1/repositories",
      "-F", "selected_repository_ids[]=100", "-F", "selected_repository_ids[]=300"
    ]]
  end

  test "place_in_group! PUTs the runner into the group; repository reads a repo's id and visibility" do
    Given
    record = JSON.generate({ "id" => 300, "full_name" => "d3mlabs/ai-flow", "visibility" => "public" })
    responder = ->(argv) { argv.include?("repos/d3mlabs/ai-flow") ? [record, "", true] : ["", "", true] }
    exec = RecordingExecutor.new(&responder)
    registry = Dev::RunnerRegistry.new(executor: exec)

    When
    registry.place_in_group!(org: "d3mlabs", group_id: 1, runner_id: 42)
    repo = registry.repository("d3mlabs/ai-flow")

    Then
    exec.captures.first == ["gh", "api", "-X", "PUT", "orgs/d3mlabs/actions/runner-groups/1/runners/42"]
    exec.captures.last == ["gh", "api", "repos/d3mlabs/ai-flow"]
    [repo.id, repo.full_name, repo.visibility, repo.public?] == [300, "d3mlabs/ai-flow", "public", true]
  end

  test "group reads raise QueryError and group writes raise AmendError when gh refuses — never a silent nothing" do
    Given
    refusing = Dev::RunnerRegistry.new(executor: RecordingExecutor.new { ["", "HTTP 403", false] })

    Expect
    assert_raises(Dev::RunnerRegistry::QueryError) { refusing.group(org: "d3mlabs", name: "Default") }.message.include?("HTTP 403")
    assert_raises(Dev::RunnerRegistry::QueryError) { refusing.group_repositories(org: "d3mlabs", group_id: 1) }.message.include?("HTTP 403")
    assert_raises(Dev::RunnerRegistry::QueryError) { refusing.repository("d3mlabs/dev") }.message.include?("HTTP 403")
    assert_raises(Dev::RunnerRegistry::AmendError) { refusing.select_group_repositories!(org: "d3mlabs", group_id: 1, repository_ids: []) }.message.include?("HTTP 403")
    assert_raises(Dev::RunnerRegistry::AmendError) { refusing.place_in_group!(org: "d3mlabs", group_id: 1, runner_id: 1) }.message.include?("HTTP 403")
    assert_raises(Dev::RunnerRegistry::AmendError) { refusing.create_group!(org: "d3mlabs", name: "x", visibility: "selected", allows_public_repositories: false, selected_workflows: []) }.message.include?("HTTP 403")
    assert_raises(Dev::RunnerRegistry::AmendError) { refusing.update_group!(org: "d3mlabs", group_id: 1, visibility: "all", selected_workflows: []) }.message.include?("HTTP 403")
  end

  private

  def runner_json(id:, name:, custom:, status: "online", busy: false)
    self.class.runner_json(id: id, name: name, custom: custom, status: status, busy: busy)
  end
end
