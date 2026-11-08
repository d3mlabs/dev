# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/runner_groups"
require "stringio"

# The registry as RunnerGroups reads and writes it: canned groups by name,
# runner placements, selections and repositories; every write recorded.
class GroupsRegistry
  attr_reader :writes

  def initialize(groups: {}, placements: {}, selections: {}, repositories: {})
    @groups = groups
    @placements = placements
    @selections = selections
    @repositories = repositories
    @writes = []
  end

  def group(org:, name:)
    @groups[[org, name]]
  end

  def create_group!(org:, name:, visibility:, allows_public_repositories:, selected_workflows:)
    @writes << [:create, org, name, visibility, allows_public_repositories, selected_workflows]
    Dev::RunnerRegistry::Group.new(id: 99, name: name, visibility: visibility, allows_public_repositories: allows_public_repositories,
      restricted_to_workflows: !selected_workflows.empty?, selected_workflows: selected_workflows)
  end

  def update_group!(org:, group_id:, selected_workflows:, visibility: nil, allows_public_repositories: nil)
    @writes << [:update, org, group_id, visibility, allows_public_repositories, selected_workflows]
    before = @groups.values.find { |group| group.id == group_id }
    Dev::RunnerRegistry::Group.new(
      id: group_id, name: before.name, visibility: visibility || before.visibility,
      allows_public_repositories: allows_public_repositories.nil? ? before.allows_public_repositories : allows_public_repositories,
      restricted_to_workflows: !selected_workflows.empty?, selected_workflows: selected_workflows,
    )
  end

  def group_of(org:, runner_id:)
    @placements[[org, runner_id]]
  end

  def place_in_group!(org:, group_id:, runner_id:)
    @writes << [:place, org, group_id, runner_id]
  end

  def group_repositories(org:, group_id:)
    @selections.fetch([org, group_id], [])
  end

  def select_group_repositories!(org:, group_id:, repository_ids:)
    @writes << [:select, org, group_id, repository_ids]
  end

  def repository(repo)
    @repositories.fetch(repo)
  end
end unless defined?(GroupsRegistry)

transform!(RSpock::AST::Transformation)
class Dev::RunnerGroupsTest < Minitest::Test
  PINS = %w[d3mlabs/ai-flow/.github/workflows/ai-commands.yml@refs/heads/main d3mlabs/ai-flow/.github/workflows/origin-firing.yml@refs/heads/main].freeze
  AI_FLOW = Dev::RunnerGroupContract.new(name: "ai-flow", workflows: PINS)
  UE_HOSTED = Dev::RunnerGroupContract.new(name: "ue-hosted")

  def group(id: 7, name: "ai-flow", visibility: "selected", restricted: true, workflows: PINS, allows_public: false)
    Dev::RunnerRegistry::Group.new(id: id, name: name, visibility: visibility, allows_public_repositories: allows_public,
      restricted_to_workflows: restricted, selected_workflows: workflows)
  end

  def repo(id, full_name, visibility)
    Dev::RunnerRegistry::Repository.new(id: id, full_name: full_name, visibility: visibility)
  end

  def selected(*names)
    names.each_with_index.map { |name, i| Dev::RunnerRegistry::GroupRepository.new(id: 100 + i, full_name: name) }
  end

  # --- converge! ------------------------------------------------------------

  test "an owned group the org lacks is created: selected, pinned, closed to public repos until one is admitted" do
    Given
    registry = GroupsRegistry.new
    out = StringIO.new

    When
    created = Dev::RunnerGroups.new(registry: registry, out: out).converge!(AI_FLOW, org: "d3mlabs")

    Then
    registry.writes == [[:create, "d3mlabs", "ai-flow", "selected", false, PINS]]
    created.name == "ai-flow"
    out.string.include?("Creating runner group 'ai-flow' at d3mlabs, pinned to")
  end

  test "an owned group that satisfies its contract is left alone, silently" do
    Given
    registry = GroupsRegistry.new(groups: { ["d3mlabs", "ai-flow"] => group })
    out = StringIO.new

    When
    found = Dev::RunnerGroups.new(registry: registry, out: out).converge!(AI_FLOW, org: "d3mlabs")

    Then
    registry.writes == []
    found.id == 7
    out.string.empty?
  end

  test "an owned group the console drifted — unpinned, or opened to every repo — is re-converged, naming the drift" do
    Given
    registry = GroupsRegistry.new(groups: { ["d3mlabs", "ai-flow"] => group(visibility: "all", restricted: false, workflows: []) })
    out = StringIO.new

    When
    healed = Dev::RunnerGroups.new(registry: registry, out: out).converge!(AI_FLOW, org: "d3mlabs")

    Then
    registry.writes == [[:update, "d3mlabs", 7, "selected", nil, PINS]]
    healed.restricted_to_workflows
    out.string.include?("drifted (visibility is 'all', not 'selected'; not restricted to workflows)")
  end

  test "an open contract's group is created open to every repo, public ones included — the pin is the defense (dev#495)" do
    Given
    registry = GroupsRegistry.new
    out = StringIO.new
    orchestrator = Dev::RunnerGroupContract.new(name: "ai-orchestrator", workflows: PINS, visibility: "all")

    When
    created = Dev::RunnerGroups.new(registry: registry, out: out).converge!(orchestrator, org: "d3mlabs")

    Then
    registry.writes == [[:create, "d3mlabs", "ai-orchestrator", "all", true, PINS]]
    created.name == "ai-orchestrator"
    !created.selected?
  end

  test "an open contract's group the console narrowed to selected repos is re-opened, naming the drift" do
    Given
    registry = GroupsRegistry.new(groups: { ["d3mlabs", "ai-orchestrator"] => group(name: "ai-orchestrator") })
    out = StringIO.new
    orchestrator = Dev::RunnerGroupContract.new(name: "ai-orchestrator", workflows: PINS, visibility: "all")

    When
    healed = Dev::RunnerGroups.new(registry: registry, out: out).converge!(orchestrator, org: "d3mlabs")

    Then
    registry.writes == [[:update, "d3mlabs", 7, "all", nil, PINS]]
    !healed.selected?
    out.string.include?("drifted (visibility is 'selected', not 'all')")
  end

  test "re-pinning a group that is already selected does not name visibility: a PATCH naming it wipes the selected repositories (plans#5 H3)" do
    Given "a selected group restricted to nothing (what an incomplete PATCH leaves) with repos it must keep"
    registry = GroupsRegistry.new(groups: { ["d3mlabs", "ai-flow"] => group(restricted: true, workflows: []) })
    out = StringIO.new

    When
    healed = Dev::RunnerGroups.new(registry: registry, out: out).converge!(AI_FLOW, org: "d3mlabs")

    Then
    registry.writes == [[:update, "d3mlabs", 7, nil, nil, PINS]]
    healed.pinned?
    out.string.include?("drifted (pinned to nothing")
  end

  test "a named group must exist: dev never creates a human's group, and says where to" do
    Given
    registry = GroupsRegistry.new(groups: { ["d3mlabs", "ue-hosted"] => group(id: 3, name: "ue-hosted", restricted: false, workflows: []) })
    groups = Dev::RunnerGroups.new(registry: registry, out: StringIO.new)

    Expect
    groups.converge!(UE_HOSTED, org: "d3mlabs").id == 3
    error = assert_raises(Dev::RunnerGroups::NoSuchGroupError) { groups.converge!(Dev::RunnerGroupContract.new(name: "agents"), org: "d3mlabs") }
    error.message.include?("no runner group named 'agents'")
    registry.writes == []
  end

  # --- place! -------------------------------------------------------------------

  test "place! moves a runner into the group only when it sits elsewhere" do
    Given
    default = group(id: 1, name: "Default", restricted: false, workflows: [])
    registry = GroupsRegistry.new(placements: { ["d3mlabs", 1] => default, ["d3mlabs", 2] => group })
    out = StringIO.new
    groups = Dev::RunnerGroups.new(registry: registry, out: out)
    runner = ->(id) { Dev::RunnerRegistry::Runner.new(id: id, custom_labels: [], status: "online") }

    When
    groups.place!(group, runner.call(1), org: "d3mlabs")
    groups.place!(group, runner.call(2), org: "d3mlabs")

    Then
    registry.writes == [[:place, "d3mlabs", 7, 1]]
    out.string.include?("Moving runner 1 into group 'ai-flow' from 'Default'")
  end

  # --- admit! -------------------------------------------------------------------

  test "admit! adds a private repo to the selection, written whole with what was there" do
    Given
    registry = GroupsRegistry.new(
      selections: { ["d3mlabs", 7] => selected("d3mlabs/dev") },
      repositories: { "d3mlabs/cellbound" => repo(300, "d3mlabs/cellbound", "private") },
    )
    out = StringIO.new

    When
    Dev::RunnerGroups.new(registry: registry, out: out).admit!(group, "d3mlabs/cellbound", org: "d3mlabs")

    Then
    registry.writes == [[:select, "d3mlabs", 7, [100, 300]]]
    out.string.include?("d3mlabs/cellbound may use group 'ai-flow' (with d3mlabs/dev)")
  end

  test "admit! is a no-op for a repo already selected (any case) or a group open to every repo" do
    Given
    registry = GroupsRegistry.new(selections: { ["d3mlabs", 7] => selected("d3mlabs/Dev") })
    out = StringIO.new
    groups = Dev::RunnerGroups.new(registry: registry, out: out)

    When
    groups.admit!(group, "d3mlabs/dev", org: "d3mlabs")
    groups.admit!(group(visibility: "all"), "d3mlabs/anything", org: "d3mlabs")

    Then
    registry.writes == []
    out.string.include?("d3mlabs/dev may use group 'ai-flow'.")
    out.string.include?("d3mlabs/anything may use group 'ai-flow' (open to every repo at d3mlabs)")
  end

  test "admit! of a public repo into a pinned group turns on allows_public_repositories first, then selects it" do
    Given
    registry = GroupsRegistry.new(
      groups: { ["d3mlabs", "ai-flow"] => group },
      repositories: { "d3mlabs/dev" => repo(100, "d3mlabs/dev", "public") },
    )
    out = StringIO.new

    When
    Dev::RunnerGroups.new(registry: registry, out: out).admit!(group, "d3mlabs/dev", org: "d3mlabs")

    Then "the flag flip carries the pins — an omitted selected_workflows would wipe them"
    registry.writes == [[:update, "d3mlabs", 7, nil, true, PINS], [:select, "d3mlabs", 7, [100]]]
    out.string.include?("now allows public repositories (d3mlabs/dev is public; pinned to")
  end

  test "the invariant: a public repo may only use a group pinned to at least one workflow — #{why} is refused, naming plans#5 H3, with nothing written" do
    Given
    registry = GroupsRegistry.new(repositories: { "d3mlabs/dev" => repo(100, "d3mlabs/dev", "public") })
    unpinned = group(id: 1, name: "Default", restricted: restricted, workflows: [])

    When
    Dev::RunnerGroups.new(registry: registry, out: StringIO.new).admit!(unpinned, "d3mlabs/dev", org: "d3mlabs")

    Then
    error = raises Dev::RunnerGroups::UnpinnedGroupError
    error.message.include?("d3mlabs/dev is public and group 'Default' is not pinned to any workflow")
    error.message.include?("plans#5 H3")
    registry.writes == []

    Where
    restricted | why
    false      | "an unrestricted group"
    true       | "a group restricted to no workflow at all"
  end

  # --- exclude! -----------------------------------------------------------------

  test "exclude! removes a repo from the selection, written whole; already absent is a no-op; an open group cannot be narrowed" do
    Given
    registry = GroupsRegistry.new(selections: { ["d3mlabs", 7] => selected("d3mlabs/dev", "d3mlabs/Cellbound-3D") })
    out = StringIO.new
    groups = Dev::RunnerGroups.new(registry: registry, out: out)

    When
    groups.exclude!(group, "d3mlabs/cellbound-3d", org: "d3mlabs")
    groups.exclude!(group, "d3mlabs/plans", org: "d3mlabs")

    Then
    registry.writes == [[:select, "d3mlabs", 7, [100]]]
    out.string.include?("d3mlabs/cellbound-3d may no longer use group 'ai-flow' (left: d3mlabs/dev)")
    out.string.include?("d3mlabs/plans already cannot use group 'ai-flow'")
    error = assert_raises(Dev::RunnerGroups::Error) { groups.exclude!(group(visibility: "all"), "d3mlabs/dev", org: "d3mlabs") }
    error.message.include?("open to every repo")
  end
end
