# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/builtins/runner_register_command"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/engine_resources"
require "dev/enrolled_runner"
require "dev/environment_image"
require "dev/host_reach"
require "dev/label_contracts"
require "dev/runner_discovery"
require "dev/runner_registry"
require "dev/runner_setup_config"
require "dev/runner_teardown"
require "dev/runner_user"
require "dev/wsl_runner_host"
require "etc"
require "fileutils"
require "json"
require "pathname"
require "stringio"
require "support/recording_ui"
require "tmpdir"

# Records the contract lifecycle a register run drives.
class RecordedContract
  attr_reader :events

  def initialize(events)
    @events = events
  end

  def converge!(container:, cpus: nil, memory_gib: nil, disk_gib: nil)
    @events << [:converge, container, cpus, memory_gib, disk_gib]
  end

  def after_enroll!(runner_dir:, slot:)
    @events << [:after_enroll, runner_dir, slot]
  end
end unless defined?(RecordedContract)

# The GitHub-side registry seam: answers find from a canned map and
# records amends; knows an org's runner groups ([org, name] => Group;
# every org has an unpinned Default open to all repos unless a test says
# otherwise), which group each runner id sits in, each group's selected
# repos, and the repos themselves (private, with a derived id, unless
# named) — and records every group write.
class FakeRegistry
  attr_reader :amends, :group_writes

  PINS = Dev::LabelContracts::AI_FLOW_WORKFLOWS

  class << self
    def group(id:, name:, visibility: "selected", pinned: false, allows_public: false)
      Dev::RunnerRegistry::Group.new(id: id, name: name, visibility: visibility, allows_public_repositories: allows_public,
        restricted_to_workflows: pinned, selected_workflows: pinned ? PINS : [])
    end
  end

  def initialize(runners: {}, groups: {}, placements: {}, selections: {}, repositories: {}, refused: [])
    @runners = runners
    @groups = groups
    @placements = placements
    @selections = selections
    @repositories = repositories
    @refused = refused
    @amends = []
    @group_writes = []
  end

  # Scopes GitHub refuses this login at (403), lifted by a refresh.
  def grant_all!
    @refused.clear
  end

  def find(scope:, name:)
    refuse!(scope)
    @runners[[scope, name]]
  end

  def amend!(scope:, runner_id:, labels:)
    @amends << [scope, runner_id, labels]
  end

  def group(org:, name:)
    refuse!(org)
    @groups[[org, name]] || (name == "Default" ? self.class.group(id: 1, name: "Default", visibility: "all") : nil)
  end

  def refuse!(scope)
    return unless @refused.include?(scope)

    raise Dev::RunnerRegistry::QueryError, "could not list at #{scope}: gh: You must be an org admin (HTTP 403)"
  end

  def create_group!(org:, name:, visibility:, allows_public_repositories:, selected_workflows:)
    @group_writes << [:create, org, name, visibility, allows_public_repositories, selected_workflows]
    @groups[[org, name]] = Dev::RunnerRegistry::Group.new(id: 99, name: name, visibility: visibility, allows_public_repositories: allows_public_repositories,
      restricted_to_workflows: !selected_workflows.empty?, selected_workflows: selected_workflows)
  end

  def update_group!(org:, group_id:, selected_workflows:, visibility: nil, allows_public_repositories: nil)
    @group_writes << [:update, org, group_id, visibility, allows_public_repositories, selected_workflows]
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

  def group_repositories(org:, group_id:)
    @selections.fetch([org, group_id], [])
  end

  def select_group_repositories!(org:, group_id:, repository_ids:)
    @group_writes << [:select, org, group_id, repository_ids]
  end

  def place_in_group!(org:, group_id:, runner_id:)
    @group_writes << [:place, org, group_id, runner_id]
  end

  def repository(repo)
    @repositories[repo] || Dev::RunnerRegistry::Repository.new(id: repo.sum, full_name: repo, visibility: "private")
  end
end unless defined?(FakeRegistry)

transform!(RSpock::AST::Transformation)
class Dev::Cli::Builtins::RunnerRegisterCommandTest < Minitest::Test
  include SorbetHelper

  # --- usage ------------------------------------------------------------

  test "every flag register declares carries a description, so `dev runner register --help` explains each" do
    Given "the command as the CLI builds it"
    command = Dev::Cli::Builtins::RunnerRegisterCommand.new

    Expect "no flag lists by name alone"
    command.flags.all? { |flag| !flag.desc.empty? }
    command.flags.map(&:name) == [
      "--org", "--labels", "--ai-flow", "--slots", "--group",
      "--dir", "--name", "--repo", "--agent-user", "--as", "--yes"
    ]
  end

  # --- label + scope resolution ---------------------------------------

  test "bare register derives the repo label from the repo name — lowercased, dashes kept, never from dev.yml name:" do
    Given "a checkout gh resolves to #{repo}, whose dev.yml name: differs"
    harness = build_harness(repo: repo)
    context = harness.build_context(name: "Cellbound3D")

    When "running register with no flags"
    harness.command.call(args: no_args, context: context)

    Then "the label is the repo's name as GitHub spells it, repo-scoped, dir/name defaulted; the setup speaks on the context's Ui"
    config, repo_override, org, _as_user, ui = harness.wirings.fetch(0)
    config == Dev::RunnerSetupConfig.new(labels: label)
    repo_override.nil?
    org == false
    ui.equal?(harness.ui)

    Cleanup
    nil

    Where
    repo                      | label
    "d3mlabs/cellbound-3d"    | "cellbound-3d"
    "d3mlabs/unreal-engine"   | "unreal-engine"
    "JPDuchesne/snappy"       | "snappy"
    "D3MLabs/Cellbound-3D"    | "cellbound-3d"
  end

  test "--repo overrides the scope and therefore the derived label; gh is not asked" do
    Given "a checkout of one repo, registering for another"
    asked = []
    harness = build_harness(repo: "d3mlabs/cellbound-3d", repo_resolver: ->(override) {
      asked << override
      override || "d3mlabs/cellbound-3d"
    })

    When "running register with --repo and no --labels"
    harness.command.call(args: parsed_args(harness.command, ["--repo", "d3mlabs/unreal-engine"]), context: harness.build_context(name: "Cellbound3D"))

    Then "the label follows the override, which is also what the setup is wired with"
    config, repo_override, _org = harness.wirings.fetch(0)
    config.labels == "unreal-engine"
    repo_override == "d3mlabs/unreal-engine"
    asked == ["d3mlabs/unreal-engine"]
  end

  test "bare register derives the same enrolled runner the lookup asks GitHub for — one derivation, not two" do
    Given "a checkout"
    harness = build_harness(repo: "d3mlabs/cellbound-3d")

    When "running register with no flags"
    harness.command.call(args: no_args, context: harness.build_context(name: "Cellbound3D"))

    Then "the label is EnrolledRunner's, so what register enrolls is what the remote dispatch will find"
    harness.wirings.fetch(0).fetch(0).labels == Dev::EnrolledRunner.for("d3mlabs/cellbound-3d").label
  end

  test "--repo without an owner is refused before anything converges: a bare name would enroll at an org scope" do
    Given "a harness"
    harness = build_harness(contracts: 1)

    When "registering for a repo spelled without its owner"
    harness.command.call(args: parsed_args(harness.command, ["--repo", "cellbound-3d"]), context: harness.build_context(name: "Cellbound3D"))

    Then
    error = raises Dev::EnrolledRunner::MalformedRepoError
    error.message.include?("cellbound-3d")
    harness.events == []
    harness.wirings == []
  end

  test "the operator's gh login is probed before anything converges: an org it cannot read runner groups at is a refusal with the fix, not a backtrace after sudo and brew ran (dev#493)" do
    Given "an org this login cannot administer, and no terminal to answer with"
    registry = FakeRegistry.new(refused: ["d3mlabs"])
    harness = build_harness(registry: registry, scope: "d3mlabs", contracts: 1, runner_user: runner_user_mock(name: "runner", home: "/home/runner"))
    harness.ui.stubs(:confirm).returns(false)
    harness.engine.expects(:provision!).never

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ai-orchestrator"]), context: harness.projectless_context)

    Then "refused, naming the fix; no contract converged, no runner user touched, nothing enrolled"
    error = raises Dev::OperatorAccess::RefusedError
    error.message.include?("gh auth refresh -h github.com -s admin:org")
    harness.events == []
    harness.wirings == []
    harness.as_names == []
  end

  test "at a terminal the refusal offers the refresh; granted, the registration goes on as if nothing happened" do
    Given
    registry = FakeRegistry.new(refused: ["d3mlabs"], groups: { ["d3mlabs", "ai-flow"] => FakeRegistry.group(id: 7, name: "ai-flow", pinned: true) })
    refreshed = []
    harness = build_harness(registry: registry, scope: "d3mlabs", refresher: ->(scope) {
      refreshed << scope
      registry.grant_all!
      true
    })
    harness.ui.stubs(:confirm).returns(true)

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ai-orchestrator"]), context: harness.projectless_context)

    Then
    refreshed == ["admin:org"]
    harness.wirings.map { |config, _repo, _org| config.labels } == ["ai-orchestrator"]
  end

  test "--org --ai-flow enrolls the agent host's full label set — never the orchestrator label" do
    Given "a harness"
    harness = build_harness

    When "registering the org agent host"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow"]), context: harness.projectless_context)

    Then "the labels are dev's documented mirror of ai-flow's agent vocabulary"
    config, _repo, org = harness.wirings.fetch(0)
    config.labels == Dev::LabelContracts::AI_FLOW_AGENT_LABELS.join(",")
    !config.labels.include?("ai-orchestrator")
    org == true
  end

  test "--org --labels ai-orchestrator --slots 2 enrolls a thin pool in its own open group — created when missing, nothing admitted — with no agent host contract (plans#53, dev#495)" do
    Given "an org with the pinned ai-flow group and no orchestrator group yet; a factory recording what contracts are asked for"
    registry = FakeRegistry.new(groups: { ["d3mlabs", "ai-flow"] => FakeRegistry.group(id: 7, name: "ai-flow", pinned: true) })
    seen = []
    recorder = ->(labels, agent_user, _runner_user, _ui) {
      seen << [labels, agent_user]
      Dev::LabelContracts.for(labels, agent_user: agent_user, bootstrap: typed_mock(Dev::AgentBootstrap))
    }
    harness = build_harness(registry: registry, scope: "d3mlabs", contracts_factory: recorder)

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ai-orchestrator", "--slots", "2"]), context: harness.projectless_context)

    Then "two slots carrying the label, in the ai-orchestrator group, which was created open to every repo and pinned; no selection written; the label set carried no agent host contract"
    harness.wirings.map { |config, _repo, _org| config.labels } == ["ai-orchestrator", "ai-orchestrator"]
    harness.wirings.map { |config, _repo, _org| config.group } == ["ai-orchestrator", "ai-orchestrator"]
    registry.group_writes == [[:create, "d3mlabs", "ai-orchestrator", "all", true, Dev::LabelContracts::AI_FLOW_WORKFLOWS]]
    harness.out.string.include?("may use group 'ai-orchestrator' (open to every repo at d3mlabs)")
    seen == [["ai-orchestrator", nil]]
    Dev::LabelContracts.for("ai-orchestrator").empty?
  end

  test "--labels mixing an agent label with ai-orchestrator is refused before anything converges: one enrollment, one group" do
    Given
    harness = build_harness(scope: "d3mlabs")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ai-build,ai-orchestrator"]), context: harness.projectless_context)

    Then
    error = raises ArgumentError
    error.message.include?("one enrollment, one group")
    harness.wirings == []
    harness.events == []
  end

  test "--labels overrides any derivation" do
    Given "a checkout whose derived label would differ"
    harness = build_harness
    context = harness.build_context(name: "UnrealEngine")

    When "registering with an explicit custom set"
    harness.command.call(args: parsed_args(harness.command, ["--labels", "macos,ue-editor"]), context: context)

    Then
    harness.wirings.fetch(0).fetch(0).labels == "macos,ue-editor"
  end

  test "--ai-flow with --labels is a contradiction and raises" do
    Given "a harness"
    harness = build_harness

    When "passing both"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow", "--labels", "ai-ask"]), context: harness.projectless_context)

    Then
    raises ArgumentError
  end

  test "--org without a role raises: an org runner's labels are not derivable" do
    Given "a harness"
    harness = build_harness

    When "registering org-scoped with no label source"
    harness.command.call(args: parsed_args(harness.command, ["--org"]), context: harness.build_context(name: "Cellbound3D"))

    Then
    raises ArgumentError
  end

  test "bare register outside a project raises: nothing to derive from" do
    Given "a harness"
    harness = build_harness

    When "registering with no checkout and no labels"
    harness.command.call(args: no_args, context: harness.projectless_context)

    Then
    raises ArgumentError
  end

  test "register applies --dir/--name/--repo/--org flags" do
    Given "a harness"
    harness = build_harness

    When "running with identity overrides"
    words = ["--labels", "ue-engine", "--dir", "~/actions-runner-ue",
             "--name", "gaming-box", "--repo", "d3mlabs/unreal-engine", "--org"]
    harness.command.call(args: parsed_args(harness.command, words), context: harness.projectless_context)

    Then
    config, repo, org = harness.wirings.fetch(0)
    config == Dev::RunnerSetupConfig.new(labels: "ue-engine", dir: "~/actions-runner-ue", name: "gaming-box")
    repo == "d3mlabs/unreal-engine"
    org == true
  end

  # --- the idempotent converge ----------------------------------------

  test "a fresh scope runs the full enrollment: converge -> enroll -> after_enroll" do
    Given "no local enrollment serves the scope"
    harness = build_harness(contracts: 1)
    context = harness.build_context(name: "Cellbound3D")

    When "registering"
    harness.command.call(args: no_args, context: context)

    Then "the ceremony runs end to end with the enrolled dir"
    harness.events == [
      [:converge, false, nil, nil, nil],
      [:run],
      [:after_enroll, "/tmp/runner-dir", 1],
    ]
  end

  test "an enrolled scope with drifted labels is amended in place, never re-enrolled" do
    Given "this host already serves the org, with a stale label set, in a repo-named dir"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs", name: "mac-box")
    registry = FakeRegistry.new(
      runners: { ["d3mlabs", "mac-box"] => Dev::RunnerRegistry::Runner.new(id: 42, custom_labels: ["cellbound3d"], status: "online") },
    )
    harness = build_harness(contracts: 1, home: home, registry: registry, scope: "d3mlabs")

    When "registering the agent host"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow"]), context: harness.projectless_context)

    Then "one label amend; the service and dir stay put; contracts still converge"
    registry.amends == [["d3mlabs", 42, Dev::LabelContracts::AI_FLOW_AGENT_LABELS]]
    harness.events == [
      [:converge, false, nil, nil, nil],
      [:after_enroll, dir, 1],
    ]
  end

  test "an enrolled scope with current labels is a no-op amend" do
    Given "the enrollment already advertises the desired set"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs/cellbound-3d", name: "box")
    registry = FakeRegistry.new(
      runners: { ["d3mlabs/cellbound-3d", "box"] => Dev::RunnerRegistry::Runner.new(id: 7, custom_labels: ["cellbound-3d"], status: "online") },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs/cellbound-3d")

    When "re-running register"
    harness.command.call(args: no_args, context: harness.build_context(name: "Cellbound3D"))

    Then "nothing is amended and nothing re-enrolls; the slot's state is one note with its glyph"
    registry.amends == []
    harness.events == []
    harness.ui.rows == [[:note, "{{v}} Runner 'box' already serves d3mlabs/cellbound-3d with labels cellbound-3d — nothing to amend", 0]]
  end

  test "a local enrollment GitHub has lost re-enrolls into the same dir" do
    Given "a .runner record whose runner is gone server-side"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs", name: "mac-box")
    harness = build_harness(home: home, registry: FakeRegistry.new, scope: "d3mlabs")

    When "registering"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ai-build"]), context: harness.projectless_context)

    Then "the re-enrollment reuses the discovered dir, not a label-derived one"
    harness.events == [[:run]]
    harness.wirings.fetch(1).fetch(0).dir == dir
  end

  # --- superseded enrollments (#238) -------------------------------------

  test "two local enrollments for the scope: register lists them, asks, and on yes unregisters both then enrolls fresh" do
    Given "the --replace aftermath: a legacy dir owning the service, a newer dir owning the (online) registration"
    home = Dir.mktmpdir
    legacy = write_runner(home, "actions-runner", scope: "JPDuchesne/snappy", name: "JPSFF")
    File.write(File.join(legacy, ".service"), "unit\n")
    newer = write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    registry = FakeRegistry.new(
      runners: { ["JPDuchesne/snappy", "JPSFF"] => Dev::RunnerRegistry::Runner.new(id: 9, custom_labels: ["snappy"], status: "online") },
    )
    harness = build_harness(contracts: 1, home: home, registry: registry, scope: "JPDuchesne/snappy", repo: "JPDuchesne/snappy")
    harness.ui.expects(:confirm).once.with("Unregister these and enroll fresh?").returns(true)

    When "registering in the snappy checkout"
    harness.command.call(args: no_args, context: harness.build_context(name: "snappy"))

    Then "both are torn down, then the fresh ceremony runs into the default (label-derived) dir"
    harness.torn_down.map(&:dir) == [legacy, newer]
    harness.events == [[:converge, false, nil, nil, nil], [:run], [:after_enroll, "/tmp/runner-dir", 1]]
    harness.wirings.last.fetch(0) == Dev::RunnerSetupConfig.new(labels: "snappy")
    registry.amends == []
    harness.ui.rows.first(3) == [
      [:note, "{{x}} JPDuchesne/snappy has 2 local enrollments named 'JPSFF' — the enrollment on disk is not what should be serving GitHub:", 0],
      [:note, "    ~/actions-runner (service installed)", 0],
      [:note, "    ~/actions-runner-snappy (no service)", 0],
    ]
  end

  test "one local enrollment whose runner GitHub lists offline: register asks; --yes answers for it" do
    Given "a registration nothing is running"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    registry = FakeRegistry.new(
      runners: { ["JPDuchesne/snappy", "JPSFF"] => Dev::RunnerRegistry::Runner.new(id: 9, custom_labels: ["snappy"], status: "offline") },
    )
    harness = build_harness(home: home, registry: registry, scope: "JPDuchesne/snappy", repo: "JPDuchesne/snappy")
    harness.ui.expects(:confirm).never

    When "registering with --yes"
    harness.command.call(args: parsed_args(harness.command, ["--yes"]), context: harness.build_context(name: "snappy"))

    Then "no prompt; torn down and enrolled fresh; nothing amended"
    harness.torn_down.map(&:dir) == [dir]
    harness.events == [[:run]]
    registry.amends == []
    harness.out.string.include?("offline")
  end

  test "declining leaves everything as it was and prints one unregister command per enrollment, exiting non-zero" do
    Given "two enrollments and an operator who says no"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner", scope: "JPDuchesne/snappy", name: "JPSFF")
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    harness = build_harness(home: home, scope: "JPDuchesne/snappy", repo: "JPDuchesne/snappy")
    harness.ui.expects(:confirm).once.returns(false)

    When "registering"
    harness.command.call(args: no_args, context: harness.build_context(name: "snappy"))

    Then "the refusal is the error the CLI maps to exit 1, carrying the remedy; nothing ran"
    error = raises Dev::Cli::Builtins::RunnerRegisterCommand::SupersededEnrollmentsError
    error.message.include?("dev runner unregister ~/actions-runner\n")
    error.message.include?("dev runner unregister ~/actions-runner-snappy")
    harness.torn_down == []
    harness.events == []
  end

  test "one local enrollment, online: the amend path, no question asked" do
    Given "the steady state"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    registry = FakeRegistry.new(
      runners: { ["JPDuchesne/snappy", "JPSFF"] => Dev::RunnerRegistry::Runner.new(id: 9, custom_labels: ["snappy"], status: "online") },
    )
    harness = build_harness(home: home, registry: registry, scope: "JPDuchesne/snappy", repo: "JPDuchesne/snappy")
    harness.ui.expects(:confirm).never

    When "registering"
    harness.command.call(args: no_args, context: harness.build_context(name: "snappy"))

    Then
    harness.torn_down == []
    harness.events == []
    harness.out.string.include?("nothing to amend")
  end

  test "--dir skips the detection along with discovery" do
    Given "two enrollments discovery would flag"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner", scope: "JPDuchesne/snappy", name: "JPSFF")
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    harness = build_harness(home: home, scope: "JPDuchesne/snappy", repo: "JPDuchesne/snappy")
    harness.ui.expects(:confirm).never

    When "registering with an explicit dir"
    harness.command.call(args: parsed_args(harness.command, ["--dir", "~/actions-runner-other"]), context: harness.build_context(name: "snappy"))

    Then
    harness.torn_down == []
    harness.events == [[:run]]
  end

  test "--dir skips discovery: the dir is the operator's to pick" do
    Given "an enrollment discovery would have found"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs", name: "mac-box")
    registry = FakeRegistry.new(
      runners: { ["d3mlabs", "mac-box"] => Dev::RunnerRegistry::Runner.new(id: 42, custom_labels: ["x"], status: "online") },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs")

    When "registering with an explicit dir"
    words = ["--org", "--labels", "ai-build", "--dir", "~/actions-runner-heavy"]
    harness.command.call(args: parsed_args(harness.command, words), context: harness.projectless_context)

    Then "the full enrollment runs there; no amend"
    harness.events == [[:run]]
    registry.amends == []
  end

  # --- slots: a host's concurrency at a scope (dev#470) ------------------

  test "--slots 3 on a fresh scope enrolls three slots: slot 1 as always, then <host>-2 and <host>-3 beside it" do
    Given "no enrollment at the org, a host named mac1"
    harness = build_harness(contracts: 1, scope: "d3mlabs", hostname: "mac1")

    When "registering the agent host with three slots"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow", "--slots", "3"]), context: harness.projectless_context)

    Then "one converge, then three enrollments, each followed by its after_enroll; slot 1 is the plain config (today's enrollment), the others name and place themselves from it"
    harness.events == [
      [:converge, false, nil, nil, nil],
      [:run], [:after_enroll, "/tmp/runner-dir", 1],
      [:run], [:after_enroll, "/tmp/runner-dir-2", 2],
      [:run], [:after_enroll, "/tmp/runner-dir-3", 3],
    ]
    labels = Dev::LabelContracts::AI_FLOW_AGENT_LABELS.join(",")
    harness.wirings.map(&:first) == [
      Dev::RunnerSetupConfig.new(labels: labels, group: "ai-flow"),
      Dev::RunnerSetupConfig.new(labels: labels, dir: "/tmp/runner-dir-2", name: "mac1-2", group: "ai-flow"),
      Dev::RunnerSetupConfig.new(labels: labels, dir: "/tmp/runner-dir-3", name: "mac1-3", group: "ai-flow"),
    ]
  end

  test "--slots 3 over a one-slot enrollment amends slot 1 in place and adds slots 2 and 3 beside its dir" do
    Given "a host already serving the org with one online runner, in a dir of its own naming"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs", name: "mac-box")
    registry = FakeRegistry.new(
      runners: { ["d3mlabs", "mac-box"] => Dev::RunnerRegistry::Runner.new(id: 42, custom_labels: ["cellbound3d"], status: "online") },
    )
    harness = build_harness(contracts: 1, home: home, registry: registry, scope: "d3mlabs")
    harness.ui.expects(:confirm).never

    When "growing to three"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow", "--slots", "3"]), context: harness.projectless_context)

    Then "slot 1 is amended, not re-enrolled; the new slots take slot 1's base (the enrollment's name) and sit beside its dir"
    registry.amends == [["d3mlabs", 42, Dev::LabelContracts::AI_FLOW_AGENT_LABELS]]
    harness.events == [
      [:converge, false, nil, nil, nil],
      [:after_enroll, dir, 1],
      [:run], [:after_enroll, "#{dir}-2", 2],
      [:run], [:after_enroll, "#{dir}-3", 3],
    ]
    harness.wirings.drop(1).map(&:first) == [
      Dev::RunnerSetupConfig.new(labels: Dev::LabelContracts::AI_FLOW_AGENT_LABELS.join(","), dir: "#{dir}-2", name: "mac-box-2", group: "ai-flow"),
      Dev::RunnerSetupConfig.new(labels: Dev::LabelContracts::AI_FLOW_AGENT_LABELS.join(","), dir: "#{dir}-3", name: "mac-box-3", group: "ai-flow"),
    ]
    harness.torn_down == []
  end

  test "re-running without --slots keeps the slot count: every slot amended, nothing added or retired" do
    Given "two slots, both online with stale labels"
    home = Dir.mktmpdir
    one = write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1")
    two = write_runner(home, "actions-runner-ai-ask-2", scope: "d3mlabs", name: "mac1-2")
    registry = FakeRegistry.new(
      runners: {
        ["d3mlabs", "mac1"] => Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-ask"], status: "online"),
        ["d3mlabs", "mac1-2"] => Dev::RunnerRegistry::Runner.new(id: 2, custom_labels: ["ai-ask"], status: "online"),
      },
    )
    harness = build_harness(contracts: 1, home: home, registry: registry, scope: "d3mlabs")
    harness.ui.expects(:confirm).never

    When "re-running register"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow"]), context: harness.projectless_context)

    Then
    registry.amends.map { |_scope, id, _labels| id } == [1, 2]
    harness.events == [[:converge, false, nil, nil, nil], [:after_enroll, one, 1], [:after_enroll, two, 2]]
    harness.torn_down == []
  end

  test "a smaller --slots lists the surplus slots, asks, and on yes unregisters them — the kept slots are amended as usual" do
    Given "three slots, asked down to one"
    home = Dir.mktmpdir
    one = write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1")
    two = write_runner(home, "actions-runner-ai-ask-2", scope: "d3mlabs", name: "mac1-2")
    three = write_runner(home, "actions-runner-ai-ask-3", scope: "d3mlabs", name: "mac1-3")
    runners = %w[mac1 mac1-2 mac1-3].each_with_index.to_h do |name, i|
      [["d3mlabs", name], Dev::RunnerRegistry::Runner.new(id: i + 1, custom_labels: Dev::LabelContracts::AI_FLOW_AGENT_LABELS, status: "online")]
    end
    registry = FakeRegistry.new(runners: runners)
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs")
    harness.ui.expects(:confirm).once.with("Unregister them?").returns(true)

    When "shrinking"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow", "--slots", "1"]), context: harness.projectless_context)

    Then "slots 2 and 3 are torn down; slot 1 stays, labels current"
    harness.torn_down.map(&:dir) == [two, three]
    harness.events == []
    registry.amends == []
    harness.out.string.include?("2 more slots than asked for")
    harness.out.string.include?("mac1-2 (~/actions-runner-ai-ask-2)")
    File.directory?(one)
  end

  test "declining the shrink changes nothing and names the unregister commands" do
    Given "two slots, asked down to one, and an operator who says no"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1")
    write_runner(home, "actions-runner-ai-ask-2", scope: "d3mlabs", name: "mac1-2")
    registry = FakeRegistry.new(
      runners: {
        ["d3mlabs", "mac1"] => Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-ask"], status: "online"),
        ["d3mlabs", "mac1-2"] => Dev::RunnerRegistry::Runner.new(id: 2, custom_labels: ["ai-ask"], status: "online"),
      },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs")
    harness.ui.expects(:confirm).once.with("Unregister it?").returns(false)

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow", "--slots", "1"]), context: harness.projectless_context)

    Then
    error = raises Dev::Cli::Builtins::RunnerRegisterCommand::SurplusSlotsError
    error.message.include?("dev runner unregister ~/actions-runner-ai-ask-2")
    harness.torn_down == []
    registry.amends == []
    harness.events == []
  end

  test "a gap in the slots is re-filled: slots 1 and 3 enrolled, bare register adds slot 2" do
    Given
    home = Dir.mktmpdir
    one = write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1")
    write_runner(home, "actions-runner-ai-ask-3", scope: "d3mlabs", name: "mac1-3")
    registry = FakeRegistry.new(
      runners: {
        ["d3mlabs", "mac1"] => Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: Dev::LabelContracts::AI_FLOW_AGENT_LABELS, status: "online"),
        ["d3mlabs", "mac1-3"] => Dev::RunnerRegistry::Runner.new(id: 3, custom_labels: Dev::LabelContracts::AI_FLOW_AGENT_LABELS, status: "online"),
      },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow"]), context: harness.projectless_context)

    Then
    harness.events == [[:run]]
    harness.wirings.last.first == Dev::RunnerSetupConfig.new(labels: Dev::LabelContracts::AI_FLOW_AGENT_LABELS.join(","), dir: "#{one}-2", name: "mac1-2", group: "ai-flow")
  end

  test "a slot GitHub has lost re-enrolls into its own dir under its own name; the rest are amended" do
    Given "two slots whose second runner is gone server-side"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1")
    two = write_runner(home, "actions-runner-ai-ask-2", scope: "d3mlabs", name: "mac1-2")
    registry = FakeRegistry.new(
      runners: { ["d3mlabs", "mac1"] => Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: Dev::LabelContracts::AI_FLOW_AGENT_LABELS, status: "online") },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs")
    harness.ui.expects(:confirm).never

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow"]), context: harness.projectless_context)

    Then
    harness.events == [[:run]]
    harness.wirings.last.first == Dev::RunnerSetupConfig.new(labels: Dev::LabelContracts::AI_FLOW_AGENT_LABELS.join(","), dir: two, name: "mac1-2", group: "ai-flow")
    harness.torn_down == []
  end

  # --- families: two org-scoped label sets on one host (dev#557) ----------

  test "the agent family enrolls beside the orchestrator pool at the same org scope: the pool is neither counted, amended nor retired, and the family takes its own base since the pool holds the hostname" do
    Given "the box: ten pool slots under the bare hostname, GitHub knowing them all as online orchestrators"
    home = Dir.mktmpdir
    registry = FakeRegistry.new(runners: pool_runners(home, count: 10, hostname: "JPSFF"))
    harness = build_harness(contracts: 1, home: home, registry: registry, scope: "d3mlabs", hostname: "JPSFF")
    harness.ui.expects(:confirm).never

    When "registering the agent host with three slots"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow", "--slots", "3"]), context: harness.projectless_context)

    Then "three fresh slots named <hostname>-<first label>[-n], the pool untouched"
    labels = Dev::LabelContracts::AI_FLOW_AGENT_LABELS.join(",")
    harness.wirings.drop(1).map(&:first) == [
      Dev::RunnerSetupConfig.new(labels: labels, dir: "/tmp/runner-dir", name: "JPSFF-ai-ask", group: "ai-flow"),
      Dev::RunnerSetupConfig.new(labels: labels, dir: "/tmp/runner-dir-2", name: "JPSFF-ai-ask-2", group: "ai-flow"),
      Dev::RunnerSetupConfig.new(labels: labels, dir: "/tmp/runner-dir-3", name: "JPSFF-ai-ask-3", group: "ai-flow"),
    ]
    harness.events == [
      [:converge, false, nil, nil, nil],
      [:run], [:after_enroll, "/tmp/runner-dir", 1],
      [:run], [:after_enroll, "/tmp/runner-dir-2", 2],
      [:run], [:after_enroll, "/tmp/runner-dir-3", 3],
    ]
    harness.torn_down == []
    registry.amends == []
    !harness.out.string.include?("more slots than asked for")
  end

  test "re-running the agent family beside the pool is a no-op on both: its own slots are amended, the pool's never named" do
    Given "the pool and a three-slot agent family under its own base, all online and current"
    home = Dir.mktmpdir
    runners = pool_runners(home, count: 10, hostname: "JPSFF")
    %w[JPSFF-ai-ask JPSFF-ai-ask-2 JPSFF-ai-ask-3].each_with_index do |name, i|
      write_runner(home, "actions-runner-ai-ask#{"-#{i + 1}" if i.positive?}", scope: "d3mlabs", name: name)
      runners[["d3mlabs", name]] = Dev::RunnerRegistry::Runner.new(id: 100 + i, custom_labels: Dev::LabelContracts::AI_FLOW_AGENT_LABELS, status: "online")
    end
    registry = FakeRegistry.new(runners: runners)
    harness = build_harness(contracts: 1, home: home, registry: registry, scope: "d3mlabs", hostname: "JPSFF")
    harness.ui.expects(:confirm).never

    When "re-running without --slots"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow"]), context: harness.projectless_context)

    Then "three after_enrolls, nothing run, nothing torn down, no surplus"
    harness.events.map(&:first) == [:converge, :after_enroll, :after_enroll, :after_enroll]
    harness.torn_down == []
    registry.amends == []
    !harness.out.string.include?("more slots than asked for")
  end

  test "the reverse order: the pool enrolls beside an agent family holding the hostname, under its own base, and a smaller --slots never counts the family's slots as surplus" do
    Given "a two-slot agent family under the bare hostname"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1")
    write_runner(home, "actions-runner-ai-ask-2", scope: "d3mlabs", name: "mac1-2")
    registry = FakeRegistry.new(
      runners: {
        ["d3mlabs", "mac1"] => Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: Dev::LabelContracts::AI_FLOW_AGENT_LABELS, status: "online"),
        ["d3mlabs", "mac1-2"] => Dev::RunnerRegistry::Runner.new(id: 2, custom_labels: Dev::LabelContracts::AI_FLOW_AGENT_LABELS, status: "online"),
      },
      groups: { ["d3mlabs", "ai-flow"] => FakeRegistry.group(id: 7, name: "ai-flow", pinned: true) },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs", hostname: "mac1")
    harness.ui.expects(:confirm).never

    When "enrolling a one-slot pool"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ai-orchestrator", "--slots", "1"]), context: harness.projectless_context)

    Then
    harness.wirings.last.first == Dev::RunnerSetupConfig.new(labels: "ai-orchestrator", dir: "/tmp/runner-dir", name: "mac1-ai-orchestrator", group: "ai-orchestrator")
    harness.events == [[:run]]
    harness.torn_down == []
    registry.amends == []
  end

  test "a pool slot GitHub has lost is still the pool's — its dir says so — not a stranger for the agent family to retire" do
    Given "the pool with one slot gone server-side, and no agent family yet"
    home = Dir.mktmpdir
    runners = pool_runners(home, count: 3, hostname: "JPSFF")
    runners.delete(["d3mlabs", "JPSFF-3"])
    registry = FakeRegistry.new(runners: runners)
    harness = build_harness(contracts: 1, home: home, registry: registry, scope: "d3mlabs", hostname: "JPSFF")
    harness.ui.expects(:confirm).never

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow"]), context: harness.projectless_context)

    Then "one fresh agent slot under its own base; nothing retired"
    harness.wirings.last.first == Dev::RunnerSetupConfig.new(labels: Dev::LabelContracts::AI_FLOW_AGENT_LABELS.join(","), dir: "/tmp/runner-dir", name: "JPSFF-ai-ask", group: "ai-flow")
    harness.torn_down == []
    !harness.out.string.include?("none of this host's slots")
  end

  test "an enrollment at the scope that is none of this host's slots — another name — is superseded like a leftover: listed, asked about, retired, then the slots enroll fresh" do
    Given "one of this host's slots and an enrollment under a name that is nobody's slot"
    home = Dir.mktmpdir
    mine = write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1")
    other = write_runner(home, "actions-runner-old", scope: "d3mlabs", name: "old-box")
    registry = FakeRegistry.new(
      runners: {
        ["d3mlabs", "mac1"] => Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-ask"], status: "online"),
        ["d3mlabs", "old-box"] => Dev::RunnerRegistry::Runner.new(id: 9, custom_labels: ["ai-ask"], status: "online"),
      },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs", hostname: "mac1")
    harness.ui.expects(:confirm).once.with("Unregister these and enroll fresh?").returns(true)

    When "registering as mac1 with two slots"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow", "--name", "mac1", "--slots", "2"]), context: harness.projectless_context)

    Then
    harness.torn_down.map(&:dir).sort == [mine, other].sort
    harness.out.string.include?("an enrollment named 'old-box' that is none of this host's slots")
    harness.events == [[:run], [:run]]
  end

  test "--slots #{raw.inspect} is refused before anything converges" do
    Given
    harness = build_harness(contracts: 1)

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow", "--slots", raw]), context: harness.projectless_context)

    Then
    error = raises ArgumentError
    error.message.include?("--slots")
    harness.events == []

    Where
    raw
    "0"
    "-1"
    "two"
    "1.5"
  end

  test "--dir with more than one slot is a contradiction: every slot is its own dir" do
    Given
    harness = build_harness

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow", "--slots", "2", "--dir", "~/x"]), context: harness.projectless_context)

    Then
    error = raises ArgumentError
    error.message.include?("--dir")
    harness.wirings == []
  end

  # --- runner groups: who may use the slots (dev#470) --------------------

  AI_FLOW_SET = Dev::LabelContracts::AI_FLOW_AGENT_LABELS.join(",")

  test "ai-flow labels oblige the ai-flow group: a fresh org registration creates it — selected, pinned to ai-flow's workflows — hands it to config.sh, and admits the checkout's repo" do
    Given "an org with no ai-flow group yet, registering from the cellbound checkout"
    registry = FakeRegistry.new
    harness = build_harness(registry: registry, scope: "d3mlabs", repo: "d3mlabs/cellbound")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow"]), context: harness.projectless_context)

    Then "created before the enrollment, the slot's config names it, the repo is selected into it (private: no public flag)"
    registry.group_writes == [
      [:create, "d3mlabs", "ai-flow", "selected", false, Dev::LabelContracts::AI_FLOW_WORKFLOWS],
      [:select, "d3mlabs", 99, ["d3mlabs/cellbound".sum]],
    ]
    harness.wirings.first.first == Dev::RunnerSetupConfig.new(labels: AI_FLOW_SET, group: "ai-flow")
    harness.out.string.include?("Creating runner group 'ai-flow' at d3mlabs")
    harness.out.string.include?("Admitting d3mlabs/cellbound to group 'ai-flow'")
  end

  test "a --labels subset of the ai-flow vocabulary is an ai-flow runner too: same group, no --ai-flow needed" do
    Given
    registry = FakeRegistry.new(groups: { ["d3mlabs", "ai-flow"] => FakeRegistry.group(id: 7, name: "ai-flow", pinned: true) })
    harness = build_harness(registry: registry, scope: "d3mlabs")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ai-build"]), context: harness.projectless_context)

    Then
    harness.wirings.first.first.group == "ai-flow"
  end

  test "an existing ai-flow group that satisfies its contract is left alone; one the console unpinned is healed before anything enrolls" do
    Given "two orgs' worth of state: a sound group already seeing the checkout's repo, and one the console opened to every repo and unpinned"
    already = [Dev::RunnerRegistry::GroupRepository.new(id: 100, full_name: "d3mlabs/cellbound-3d")]
    sound = FakeRegistry.new(groups: { ["d3mlabs", "ai-flow"] => FakeRegistry.group(id: 7, name: "ai-flow", pinned: true) }, selections: { ["d3mlabs", 7] => already })
    drifted = FakeRegistry.new(groups: { ["d3mlabs", "ai-flow"] => FakeRegistry.group(id: 7, name: "ai-flow", pinned: false, visibility: "all") })
    sound_harness = build_harness(registry: sound, scope: "d3mlabs")
    drifted_harness = build_harness(registry: drifted, scope: "d3mlabs")

    When
    sound_harness.command.call(args: parsed_args(sound_harness.command, ["--org", "--ai-flow"]), context: sound_harness.projectless_context)
    drifted_harness.command.call(args: parsed_args(drifted_harness.command, ["--org", "--ai-flow"]), context: drifted_harness.projectless_context)

    Then "the sound group needs no write at all; the drifted one is re-pinned and re-selected, then the repo admitted"
    sound.group_writes == []
    drifted.group_writes.first == [:update, "d3mlabs", 7, "selected", nil, Dev::LabelContracts::AI_FLOW_WORKFLOWS]
    drifted.group_writes.last.first == :select
    drifted_harness.out.string.include?("drifted: visibility is 'all', not 'selected'; not restricted to workflows")
  end

  test "an amended slot sitting in another group is moved into the ai-flow group; one already there is not touched" do
    Given "one slot in Default, growing to two; the ai-flow group already sees the checkout's repo"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1")
    default = FakeRegistry.group(id: 1, name: "Default", visibility: "all")
    ai_flow = FakeRegistry.group(id: 7, name: "ai-flow", pinned: true)
    registry = FakeRegistry.new(
      runners: { ["d3mlabs", "mac1"] => Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: Dev::LabelContracts::AI_FLOW_AGENT_LABELS, status: "online") },
      groups: { ["d3mlabs", "ai-flow"] => ai_flow },
      placements: { ["d3mlabs", 1] => default },
      selections: { ["d3mlabs", 7] => [Dev::RunnerRegistry::GroupRepository.new(id: 100, full_name: "d3mlabs/cellbound-3d")] },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow", "--slots", "2"]), context: harness.projectless_context)

    Then "slot 1 moved; slot 2's config carries the group for config.sh --runnergroup"
    registry.group_writes == [[:place, "d3mlabs", 7, 1]]
    harness.wirings.last.first == Dev::RunnerSetupConfig.new(labels: AI_FLOW_SET, dir: "#{dir}-2", name: "mac1-2", group: "ai-flow")
    harness.out.string.include?("Moving runner 1 into group 'ai-flow' from 'Default'")
  end

  test "the repo this registration is for is derived like the org and the label: --repo carries it, and a repo already selected is a no-op" do
    Given
    ai_flow = FakeRegistry.group(id: 7, name: "ai-flow", pinned: true)
    registry = FakeRegistry.new(
      groups: { ["d3mlabs", "ai-flow"] => ai_flow },
      selections: { ["d3mlabs", 7] => [Dev::RunnerRegistry::GroupRepository.new(id: 100, full_name: "d3mlabs/Dev")] },
    )
    harness = build_harness(registry: registry, scope: "d3mlabs", repo: "d3mlabs/cellbound")

    When "registering for dev from the cellbound checkout, via --repo"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow", "--repo", "d3mlabs/dev"]), context: harness.projectless_context)

    Then
    registry.group_writes == []
    harness.out.string.include?("✓ d3mlabs/dev may use group 'ai-flow'")
  end

  test "a public repo admitted to the pinned ai-flow group turns on allows_public_repositories first — the pin is what makes that safe" do
    Given
    ai_flow = FakeRegistry.group(id: 7, name: "ai-flow", pinned: true)
    registry = FakeRegistry.new(
      groups: { ["d3mlabs", "ai-flow"] => ai_flow },
      repositories: { "d3mlabs/dev" => Dev::RunnerRegistry::Repository.new(id: 100, full_name: "d3mlabs/dev", visibility: "public") },
    )
    harness = build_harness(registry: registry, scope: "d3mlabs", repo: "d3mlabs/dev")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow"]), context: harness.projectless_context)

    Then
    registry.group_writes == [[:update, "d3mlabs", 7, nil, true, FakeRegistry::PINS], [:select, "d3mlabs", 7, [100]]]
  end

  test "the invariant holds for a human's group too: a public repo may not be admitted to an unpinned --group, and the slot was enrolled before the refusal" do
    Given "ue-hosted, unpinned and selected, registered for from the public dev checkout"
    registry = FakeRegistry.new(
      groups: { ["d3mlabs", "ue-hosted"] => FakeRegistry.group(id: 3, name: "ue-hosted", pinned: false) },
      repositories: { "d3mlabs/dev" => Dev::RunnerRegistry::Repository.new(id: 100, full_name: "d3mlabs/dev", visibility: "public") },
    )
    harness = build_harness(registry: registry, scope: "d3mlabs", repo: "d3mlabs/dev")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ue-engine", "--group", "ue-hosted"]), context: harness.projectless_context)

    Then
    error = raises Dev::RunnerGroups::UnpinnedGroupError
    error.message.include?("plans#5 H3")
    registry.group_writes == []
    harness.events == [[:run]]
  end

  test "--group names a human's group for a custom pool: it must exist, and the checkout's repo is admitted to it" do
    Given
    registry = FakeRegistry.new(groups: { ["d3mlabs", "ue-hosted"] => FakeRegistry.group(id: 3, name: "ue-hosted") })
    harness = build_harness(registry: registry, scope: "d3mlabs", repo: "d3mlabs/unreal-engine")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ue-engine", "--group", "ue-hosted"]), context: harness.projectless_context)

    Then
    harness.wirings.first.first == Dev::RunnerSetupConfig.new(labels: "ue-engine", group: "ue-hosted")
    registry.group_writes == [[:select, "d3mlabs", 3, ["d3mlabs/unreal-engine".sum]]]
  end

  test "a --group the org does not have is refused by name before anything enrolls: a human's group is made in the org's settings" do
    Given
    harness = build_harness(scope: "d3mlabs")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ue-engine", "--group", "agents"]), context: harness.projectless_context)

    Then
    error = raises Dev::RunnerGroups::NoSuchGroupError
    error.message.include?("no runner group named 'agents'")
    harness.events == []
  end

  test "a custom pool naming no group sits in Default, so Default is what the checkout's repo is admitted to" do
    Given "a Default narrowed to selected repos"
    registry = FakeRegistry.new(groups: { ["d3mlabs", "Default"] => FakeRegistry.group(id: 1, name: "Default") })
    harness = build_harness(registry: registry, scope: "d3mlabs", repo: "d3mlabs/unreal-engine")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ue-engine"]), context: harness.projectless_context)

    Then
    harness.wirings.first.first.group.nil?
    registry.group_writes == [[:select, "d3mlabs", 1, ["d3mlabs/unreal-engine".sum]]]
  end

  test "#{words.join(" ")} is a usage error: #{why}" do
    Given
    harness = build_harness

    When
    context = words.include?("--org") ? harness.projectless_context : harness.build_context(name: "Cellbound3D")
    harness.command.call(args: parsed_args(harness.command, words), context: context)

    Then
    raises ArgumentError
    harness.wirings == []

    Where
    words                                                                  | why
    ["--labels", "x", "--group", "Default"]                                | "groups partition an org's runners"
    ["--org", "--ai-flow", "--group", "agents"]                            | "the ai-flow shortcut names its group"
    ["--org", "--labels", "ai-build", "--group", "agents"]                 | "an ai-flow label names its group"
  end

  test "--ai-flow --group ai-flow is the shortcut spelled out, not a contradiction" do
    Given
    registry = FakeRegistry.new(groups: { ["d3mlabs", "ai-flow"] => FakeRegistry.group(id: 7, name: "ai-flow", pinned: true) })
    harness = build_harness(registry: registry, scope: "d3mlabs")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow", "--group", "ai-flow"]), context: harness.projectless_context)

    Then
    harness.wirings.first.first.group == "ai-flow"
  end

  test "a repo-scoped registration under its own label touches no group at all" do
    Given
    registry = FakeRegistry.new
    harness = build_harness(registry: registry)

    When
    harness.command.call(args: no_args, context: harness.build_context(name: "Cellbound3D"))

    Then
    registry.group_writes == []
    harness.wirings.first.first.group.nil?
  end

  # --- the exclusion, derived: a repo-scoped runner for labels an org group serves ---

  test "a repo-scoped ai-flow runner whose repo may also use the org's ai-flow group: register says so, asks, and takes the repo out of the group on yes" do
    Given "cellbound-3d among the ai-flow group's repos, registering its own runner, an operator who says yes"
    registry = FakeRegistry.new(
      groups: { ["d3mlabs", "ai-flow"] => FakeRegistry.group(id: 7, name: "ai-flow", pinned: true) },
      selections: { ["d3mlabs", 7] => [
        Dev::RunnerRegistry::GroupRepository.new(id: 100, full_name: "d3mlabs/dev"),
        Dev::RunnerRegistry::GroupRepository.new(id: 200, full_name: "d3mlabs/Cellbound-3D"),
      ] },
    )
    harness = build_harness(registry: registry)
    harness.ui.expects(:confirm).once.with("Make this host's runner its only one?").returns(true)

    When
    harness.command.call(args: parsed_args(harness.command, ["--ai-flow"]), context: harness.build_context(name: "Cellbound3D"))

    Then "the slot was enrolled at repo scope with no group, then the repo left the org group — the list written whole"
    harness.wirings.first.first == Dev::RunnerSetupConfig.new(labels: AI_FLOW_SET)
    registry.group_writes == [[:select, "d3mlabs", 7, [100]]]
    harness.out.string.include?("d3mlabs/cellbound-3d may also use the org's 'ai-flow' runners for these labels — its jobs would land on either")
    harness.out.string.include?("Excluding d3mlabs/cellbound-3d from group 'ai-flow'")
  end

  test "declining keeps the repo in the org's group — pooling is a legitimate answer — and says so; --yes answers yes" do
    Given
    make = lambda do
      FakeRegistry.new(
        groups: { ["d3mlabs", "ai-flow"] => FakeRegistry.group(id: 7, name: "ai-flow", pinned: true) },
        selections: { ["d3mlabs", 7] => [Dev::RunnerRegistry::GroupRepository.new(id: 200, full_name: "d3mlabs/cellbound-3d")] },
      )
    end
    declined = make.call
    declining = build_harness(registry: declined)
    declining.ui.expects(:confirm).once.returns(false)
    headless = make.call
    yes = build_harness(registry: headless)
    yes.ui.expects(:confirm).never

    When
    declining.command.call(args: parsed_args(declining.command, ["--ai-flow"]), context: declining.build_context(name: "Cellbound3D"))
    yes.command.call(args: parsed_args(yes.command, ["--ai-flow", "--yes"]), context: yes.build_context(name: "Cellbound3D"))

    Then
    declined.group_writes == []
    declining.out.string.include?("Left as is: d3mlabs/cellbound-3d keeps using the org's 'ai-flow' runners too")
    headless.group_writes == [[:select, "d3mlabs", 7, []]]
  end

  test "nothing to ask when #{why}" do
    Given
    harness = build_harness(registry: registry)
    harness.ui.expects(:confirm).never

    When
    harness.command.call(args: parsed_args(harness.command, words), context: harness.build_context(name: "Cellbound3D"))

    Then
    registry.group_writes == []
    !harness.out.string.include?("may also use")

    Where
    words         | registry                                                                                                                                                                                                   | why
    ["--ai-flow"] | FakeRegistry.new                                                                                                                                                                                           | "the org has no ai-flow group"
    ["--ai-flow"] | FakeRegistry.new(groups: { ["d3mlabs", "ai-flow"] => FakeRegistry.group(id: 7, name: "ai-flow", pinned: true) })                                                                                           | "the repo is not among the group's repos"
    ["--ai-flow"] | FakeRegistry.new(groups: { ["d3mlabs", "ai-flow"] => FakeRegistry.group(id: 7, name: "ai-flow", pinned: true, visibility: "all") })                                                                        | "the group is open to every repo (not dev's list to edit)"
    []            | FakeRegistry.new(groups: { ["d3mlabs", "ai-flow"] => FakeRegistry.group(id: 7, name: "ai-flow", pinned: true) }, selections: { ["d3mlabs", 7] => [Dev::RunnerRegistry::GroupRepository.new(id: 200, full_name: "d3mlabs/cellbound-3d")] }) | "the labels oblige no group"
  end

  test "an org this login cannot read leaves the question unasked and unanswered, out loud — a repo admin need not be an org admin" do
    Given
    registry = FakeRegistry.new
    registry.define_singleton_method(:group) { |org:, name:| raise Dev::RunnerRegistry::QueryError, "could not list the runner groups at #{org}: HTTP 403" }
    harness = build_harness(registry: registry)
    harness.ui.expects(:confirm).never

    When
    harness.command.call(args: parsed_args(harness.command, ["--ai-flow"]), context: harness.build_context(name: "Cellbound3D"))

    Then
    harness.wirings.first.first == Dev::RunnerSetupConfig.new(labels: AI_FLOW_SET)
    harness.out.string.include?("Could not read d3mlabs's runner groups (could not list the runner groups at d3mlabs: HTTP 403) — whether d3mlabs/cellbound-3d also uses the org's runners is unchecked")
  end

  # --- contracts --------------------------------------------------------

  test "register hands the contract the container fact and sizing hint" do
    Given "a container repo (its lock pins an image) with an `engine:` block"
    harness = build_harness(contracts: 1)
    engine = Dev::EngineResources::Hint.new(cpus: 8, memory_gib: 24)
    context = harness.build_context(name: "Cellbound3D", root: image_checkout, engine: engine)

    When "registering"
    harness.command.call(args: no_args, context: context)

    Then
    harness.events.fetch(0) == [:converge, true, 8, 24, nil]
  end

  test "register brings the engine up for the checked-out repo's hint before converging contracts (#197)" do
    Given "a container repo with an `engine:` block and an engine provisioner that records its call"
    harness = build_harness(contracts: 1)
    resources = Dev::EngineResources::Hint.new(cpus: 8, memory_gib: 24)
    harness.engine.expects(:provision!).once.with do |resources:|
      harness.events << [:engine, resources.cpus, resources.memory_gib]
      true
    end
    context = harness.build_context(name: "Cellbound3D", root: image_checkout, engine: resources)

    When "registering"
    harness.command.call(args: no_args, context: context)

    Then "the engine step is register's first act — same entry as `dev up`'s — then the contracts"
    harness.events.first(2) == [[:engine, 8, 24], [:converge, true, 8, 24, nil]]
  end

  test "register without a project (--org) has no hint and leaves the engine alone" do
    Given "an org registration from outside any checkout"
    harness = build_harness
    harness.engine.expects(:provision!).never

    When "registering"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ai-build"]), context: harness.projectless_context)

    Then
    true
  end

  test "a project whose lock pins no image registers without touching the engine" do
    Given "a plain repo"
    harness = build_harness
    harness.engine.expects(:provision!).never

    When "registering"
    harness.command.call(args: no_args, context: harness.build_context(name: "Plain"))

    Then
    true
  end

  test "the --agent-user flag reaches the contracts factory; without a host rule (a Mac) no runner user does" do
    Given "a factory recording its arguments"
    seen = []
    recorder = ->(labels, agent_user, runner_user, ui) {
      seen << [labels, agent_user, runner_user, ui]
      []
    }
    harness = build_harness(contracts_factory: recorder)

    When "registering with the override"
    words = ["--org", "--ai-flow", "--agent-user", "ci"]
    harness.command.call(args: parsed_args(harness.command, words), context: harness.projectless_context)

    Then "and the context's Ui goes with them, for the bootstrap to speak on"
    seen == [[Dev::LabelContracts::AI_FLOW_AGENT_LABELS.join(","), "ci", nil, harness.ui]]
  end

  # plans#59: on Linux the sudoers edge is runner → agent, so the contracts
  # learn who the runner user is from the host rule register converged.
  test "under the host rule, the runner user's name reaches the contracts factory" do
    Given "a Linux host (a runner user) and a factory recording its arguments"
    seen = []
    recorder = ->(labels, agent_user, runner_user, _ui) {
      seen << [labels, agent_user, runner_user]
      []
    }
    harness = build_harness(contracts_factory: recorder, runner_user: runner_user_mock(name: "runner", home: Dir.mktmpdir))

    When "registering"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow"]), context: harness.projectless_context)

    Then
    seen == [[Dev::LabelContracts::AI_FLOW_AGENT_LABELS.join(","), nil, "runner"]]
  end

  # --- the host rule: a runner user on Linux (dev#310) -----------------

  test "on Linux, register converges the shared data root and the runner user, checks its gh login, then enrolls as it" do
    Given "a Linux host (the factory answers a runner user) and a fresh scope"
    runner_home = Dir.mktmpdir
    runner_user = runner_user_mock(name: "runner", home: runner_home)
    provisioner = typed_mock(Dev::LinuxDataRootProvisioner)
    harness = build_harness(contracts: 1, runner_user: runner_user, data_root_provisioner: provisioner)
    sequence = sequence("host rule")
    provisioner.expects(:provision!).once.with(ui: harness.ui).in_sequence(sequence)
    runner_user.expects(:converge!).once.in_sequence(sequence)
    # The login gate asks at the terminal through the runner user's own Ui (the factory handed it the context's).
    runner_user.expects(:ensure_gh_authenticated!).once.with.in_sequence(sequence)

    When "registering in the checkout"
    harness.command.call(args: no_args, context: harness.build_context(name: "cellbound3d"))

    Then "the identity work precedes the contracts and the enrollment; the setup is wired for the runner user; no --as was named; the user speaks on the context's Ui"
    harness.events == [[:converge, false, nil, nil, nil], [:run], [:after_enroll, "/tmp/runner-dir", 1]]
    harness.wirings.fetch(0).fetch(3) == runner_user
    harness.as_names == [nil]
    harness.factory_uis == [harness.ui]
  end

  test "with a checkout, register checks the runner user's reach over the lock after the gh login and before any contract: unreachable refuses with the grants" do
    Given "a runner user that cannot read one of the repo's gh pins"
    runner_user = runner_user_mock(name: "runner", home: Dir.mktmpdir)
    reach = typed_mock(Dev::HostReach)
    pins = [Dev::Deps::Dependency.new(name: "ue", integration: :gh, group: "build", version: "1", hash: nil, metadata: { "repo" => "d3mlabs/unreal-engine" })]
    reach.expects(:check!).once.with(pins).raises(Dev::HostReach::UnreachableError, "runner cannot read d3mlabs/unreal-engine")
    harness = build_harness(contracts: 1, runner_user: runner_user, reach: reach, pins: pins)

    When
    harness.command.call(args: no_args, context: harness.build_context(name: "cellbound3d"))

    Then "the lock was read from the checkout; nothing converged or enrolled"
    error = raises Dev::HostReach::UnreachableError
    error.message.include?("d3mlabs/unreal-engine")
    harness.reach_roots == [Pathname.new("/tmp/runner-test")]
    harness.events == []
    harness.wirings == []
  end

  test "reach is not checked without a checkout (--org) or without a runner user (a Mac)" do
    Given
    reach = typed_mock(Dev::HostReach)
    reach.expects(:check!).never
    org = build_harness(runner_user: runner_user_mock(name: "runner", home: Dir.mktmpdir), reach: reach)
    mac = build_harness(runner_user: nil, reach: reach)

    When
    org.command.call(args: parsed_args(org.command, ["--org", "--ai-flow"]), context: org.projectless_context)
    mac.command.call(args: no_args, context: mac.build_context(name: "cellbound3d"))

    Then
    org.reach_roots == []
    mac.reach_roots == []
  end

  test "--as names the runner user the host rule converges" do
    Given
    runner_user = runner_user_mock(name: "ci", home: Dir.mktmpdir)
    harness = build_harness(runner_user: runner_user)

    When
    harness.command.call(args: parsed_args(harness.command, ["--as", "ci"]), context: harness.build_context(name: "cellbound3d"))

    Then
    harness.as_names == ["ci"]
    harness.wirings.fetch(0).fetch(3) == runner_user
  end

  test "a runner user with no gh login stops register before any contract or enrollment: the error carries the login command" do
    Given
    runner_user = runner_user_mock(name: "runner", home: Dir.mktmpdir)
    runner_user.stubs(:ensure_gh_authenticated!).raises(Dev::RunnerUser::GhLoginRequiredError, "sudo -iu runner gh auth login --with-token")
    harness = build_harness(contracts: 1, runner_user: runner_user)

    When
    harness.command.call(args: no_args, context: harness.build_context(name: "cellbound3d"))

    Then
    error = raises Dev::RunnerUser::GhLoginRequiredError
    error.message.include?("gh auth login --with-token")
    harness.events == []
    harness.wirings == []
  end

  test "an enrollment owned by another user — the operator's own, from before the rule — is drift: register says whose it is, asks, tears it down and enrolls fresh as the runner user" do
    Given "an online enrollment in the operator's home, and a runner user as the rule (named so it cannot be this test's own user: hosted CI runs as `runner`)"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    registry = FakeRegistry.new(
      runners: { ["JPDuchesne/snappy", "JPSFF"] => Dev::RunnerRegistry::Runner.new(id: 9, custom_labels: ["snappy"], status: "online") },
    )
    runner_user = runner_user_mock(name: "svc-runner", home: Dir.mktmpdir)
    harness = build_harness(home: home, registry: registry, scope: "JPDuchesne/snappy", repo: "JPDuchesne/snappy", runner_user: runner_user)
    harness.ui.expects(:confirm).once.with("Unregister these and enroll fresh?").returns(true)

    When "registering in the snappy checkout"
    harness.command.call(args: no_args, context: harness.build_context(name: "snappy"))

    Then "torn down (as its owner — the teardown's business), then the fresh ceremony as the runner user; nothing amended"
    harness.torn_down.map(&:dir) == [dir]
    harness.events == [[:run]]
    harness.wirings.fetch(0).fetch(3) == runner_user
    registry.amends == []
    harness.out.string.include?("runs as #{Etc.getpwuid(Process.uid).name}, not svc-runner")
    harness.out.string.include?("~/actions-runner-snappy (no service)")
  end

  test "an enrollment under the runner user's home, owned by it and online, is the steady state: the amend path, no question" do
    Given "the enrollment where the rule puts it (owned by this test's user, who plays the runner user)"
    runner_home = Dir.mktmpdir
    write_runner(runner_home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    registry = FakeRegistry.new(
      runners: { ["JPDuchesne/snappy", "JPSFF"] => Dev::RunnerRegistry::Runner.new(id: 9, custom_labels: ["snappy"], status: "online") },
    )
    runner_user = runner_user_mock(name: Etc.getpwuid(Process.uid).name, home: runner_home)
    harness = build_harness(home: Dir.mktmpdir, registry: registry, scope: "JPDuchesne/snappy", repo: "JPDuchesne/snappy", runner_user: runner_user)
    harness.ui.expects(:confirm).never

    When "registering"
    harness.command.call(args: no_args, context: harness.build_context(name: "snappy"))

    Then
    harness.torn_down == []
    harness.events == []
    harness.out.string.include?("nothing to amend")
  end

  test "on a Mac there is no runner user: no data root step, the setup wired for the invoking user" do
    Given "the factory answers nil, as RunnerUser.for_host does off Linux"
    provisioner = typed_mock(Dev::LinuxDataRootProvisioner)
    provisioner.expects(:provision!).never
    harness = build_harness(runner_user: nil, data_root_provisioner: provisioner)

    When
    harness.command.call(args: no_args, context: harness.build_context(name: "cellbound3d"))

    Then
    harness.wirings.fetch(0).fetch(3).nil?
  end

  # --- the WSL runner host (dev#261) ------------------------------------

  test "in a WSL2 distro, register converges the WSL runner host with the checkout's engine hint, after the runner user and before any contract" do
    Given "a Linux host in WSL: a runner user and a WSL runner host, and a checkout with an engine hint"
    runner_user = runner_user_mock(name: "runner", home: Dir.mktmpdir)
    wsl_runner_host = typed_mock(Dev::WslRunnerHost)
    hint = Dev::EngineResources::Hint.new(cpus: 8, memory_gib: 24)
    harness = build_harness(contracts: 1, runner_user: runner_user, wsl_runner_host: wsl_runner_host)
    sequence = sequence("wsl runner host")
    runner_user.expects(:ensure_gh_authenticated!).once.in_sequence(sequence)
    wsl_runner_host.expects(:converge!).once.with(resources: hint).in_sequence(sequence)

    When "registering in the checkout"
    harness.command.call(args: no_args, context: harness.build_context(name: "cellbound3d", engine: hint))

    Then "the contract and the enrollment came after"
    harness.events == [[:converge, false, 8, 24, nil], [:run], [:after_enroll, "/tmp/runner-dir", 1]]
  end

  test "the WSL runner host refusing (no interop, a restart due) stops register before any contract or enrollment" do
    Given
    wsl_runner_host = typed_mock(Dev::WslRunnerHost)
    wsl_runner_host.stubs(:converge!).raises(Dev::WslRunnerHost::RestartRequiredError, "wsl --shutdown, then `dev runner register` again")
    harness = build_harness(contracts: 1, wsl_runner_host: wsl_runner_host)

    When
    harness.command.call(args: no_args, context: harness.build_context(name: "cellbound3d"))

    Then
    error = raises Dev::WslRunnerHost::RestartRequiredError
    error.message.include?("wsl --shutdown")
    harness.events == []
    harness.wirings == []
  end

  test "off WSL (a Mac, a bare Linux box) there is no WSL runner host step: --org without a checkout converges nothing Windows-side" do
    Given "the default harness: the WSL runner host is nil, as WslRunnerHost.for_host answers off WSL"
    harness = build_harness(contracts: 1)

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow"]), context: harness.projectless_context)

    Then
    harness.events == [[:converge, false, nil, nil, nil], [:run], [:after_enroll, "/tmp/runner-dir", 1]]
  end

  test "register's usage carries the three-identity table and the runner-user rule: who mints, who owns, who installs; the login line; examples" do
    Given "the full desc, as `dev runner register --help` prints it"
    desc = Dev::Cli::Builtins::RunnerRegisterCommand.new.desc

    Expect "a one-line summary first, then the detail"
    desc.lines.fetch(0).chomp == "Enroll this host as a self-hosted runner, converging label contracts (--org, --labels, --ai-flow)"
    desc.include?("mints the registration token")
    desc.include?("owns the enrollment")
    desc.include?("installs the service unit")
    desc.include?("runner user")
    desc.include?("sudo -iu runner gh auth login --with-token")
    desc.include?("classic token with repo, read:org, read:packages")
    desc.include?("host PATH")
    desc.include?("brew's prefix is the runner user's")
    desc.include?("trust the deployment's tap")
    desc.include?("sudo -iu runner brew")
    desc.include?("/etc/profile.d/linuxbrew.sh")
    desc.include?("dev runner register --org --ai-flow")
    desc.include?("GITHUB_TOKEN")
  end

  test "--as carries a description, like every register flag" do
    Expect
    Dev::Cli::Builtins::RunnerRegisterCommand.new.flags.map(&:name).include?("--as")
  end

  # --- plumbing ---------------------------------------------------------

  test "the default factories build the real collaborators" do
    Given "a command with its default wiring, every construction boundary intercepted"
    # RunnerSetup#run registers the host, so the test intercepts the
    # construction boundary and asserts the default factories' wiring (the
    # bare ue-engine label makes the default contracts factory resolve to no
    # contracts). Discovery is redirected at an empty home so the run never
    # depends on this machine's enrollments, and the host rule is answered
    # at its platform seam so the run never converges a user on this one.
    empty_discovery = Dev::RunnerDiscovery.new(home: Dir.mktmpdir)
    Dev::RunnerDiscovery.expects(:new).returns(empty_discovery)
    context = projectless_context
    Dev::RunnerUser.expects(:for_host).once.with(name: "ci", ui: context.ui).returns(nil)
    # The two gh seams the default wiring reaches before anything converges:
    # the checkout's repo, and the operator pre-flight's probe of its runners.
    Dev::RunnerSetup.expects(:current_repo).once.returns("owner/repo")
    registry = typed_mock(Dev::RunnerRegistry)
    registry.expects(:find).once.with(scope: "owner/repo", name: "").returns(nil)
    Dev::RunnerRegistry.expects(:new).returns(registry)
    setup = typed_mock(Dev::RunnerSetup)
    setup.expects(:run).once
    setup.stubs(:resolve_dir).returns("/tmp/runner-dir")
    setup.stubs(:resolve_scope).returns("owner/repo")
    Dev::RunnerSetup.expects(:new)
      .with(config: Dev::RunnerSetupConfig.new(labels: "ue-engine"), repo: nil, org: false, as_user: nil, home: nil, path: nil, ui: context.ui).returns(setup)
    command = Dev::Cli::Builtins::RunnerRegisterCommand.new(data_root_provisioner: nil)

    When "running register with --as, the host rule's one input"
    command.call(args: parsed_args(command, ["--labels", "ue-engine", "--as", "ci"]), context: context)

    Then "the expectations on the construction boundary hold"
    true
  end

  test "the default pins reader is the checkout's lock and the default reach factory is HostReach over the runner user" do
    Given "a checkout with one gh pin in its lock, a runner user as the host rule, and HostReach intercepted at construction"
    root = Dir.mktmpdir
    File.write(File.join(root, "deps.lock"), "gh:\n  UnrealEngine:\n    group: build\n    version: 5.6.1-css-83\n    repo: satisfactorymodding/UnrealEngine\n")
    empty_discovery = Dev::RunnerDiscovery.new(home: Dir.mktmpdir)
    # Once for the default wiring, once when it widens to the runner user's home.
    Dev::RunnerDiscovery.expects(:new).twice.returns(empty_discovery)
    runner_user = runner_user_mock(name: "svc-runner", home: Dir.mktmpdir)
    context = build_context(name: "snappy", root: root)
    Dev::RunnerUser.expects(:for_host).once.with(name: nil, ui: context.ui).returns(runner_user)
    reach = typed_mock(Dev::HostReach)
    the_lock = ->(pins) { pins.map(&:name) == ["UnrealEngine"] && pins.fetch(0).metadata.fetch("repo") == "satisfactorymodding/UnrealEngine" }
    reach.expects(:check!).once.with(&the_lock)
    Dev::HostReach.expects(:new).once.with(identity: runner_user).returns(reach)
    Dev::RunnerSetup.expects(:current_repo).once.returns("owner/repo")
    registry = typed_mock(Dev::RunnerRegistry)
    registry.expects(:find).once.with(scope: "owner/repo", name: "").returns(nil)
    Dev::RunnerRegistry.expects(:new).returns(registry)
    setup = typed_mock(Dev::RunnerSetup)
    setup.expects(:run).once
    setup.stubs(:resolve_dir).returns("/tmp/runner-dir")
    setup.stubs(:resolve_scope).returns("owner/repo")
    Dev::RunnerSetup.expects(:new)
      .with(config: Dev::RunnerSetupConfig.new(labels: "ue-engine"), repo: nil, org: false, as_user: "svc-runner", home: runner_user.home, path: "/opt/brew/bin:/usr/bin", ui: context.ui).returns(setup)
    command = Dev::Cli::Builtins::RunnerRegisterCommand.new(data_root_provisioner: nil)

    When "registering in that checkout with default wiring"
    command.call(args: parsed_args(command, ["--labels", "ue-engine"]), context: context)

    Then "the lock was read from the checkout and checked as the runner user"
    true
  end

  test "the default repo resolver asks RunnerSetup.current_repo — the one gh seam" do
    Given "a bare register with default wiring, gh answered at RunnerSetup's seam"
    empty_discovery = Dev::RunnerDiscovery.new(home: Dir.mktmpdir)
    Dev::RunnerDiscovery.expects(:new).returns(empty_discovery)
    Dev::RunnerSetup.expects(:current_repo).once.returns("d3mlabs/Cellbound-3D")
    registry = typed_mock(Dev::RunnerRegistry)
    registry.expects(:find).once.with(scope: "d3mlabs/Cellbound-3D", name: "").returns(nil)
    Dev::RunnerRegistry.expects(:new).returns(registry)
    setup = typed_mock(Dev::RunnerSetup)
    setup.expects(:run).once
    setup.stubs(:resolve_dir).returns("/tmp/runner-dir")
    setup.stubs(:resolve_scope).returns("d3mlabs/Cellbound-3D")
    context = build_context(name: "Cellbound3D")
    Dev::RunnerSetup.expects(:new)
      .with(config: Dev::RunnerSetupConfig.new(labels: "cellbound-3d"), repo: nil, org: false, as_user: nil, home: nil, path: nil, ui: context.ui).returns(setup)
    command = Dev::Cli::Builtins::RunnerRegisterCommand.new(runner_user_factory: ->(_name, _ui) { nil }, data_root_provisioner: nil)

    When "running bare register inside a checkout whose dev.yml name differs"
    command.call(args: no_args, context: context)

    Then "the label came from gh's repo name, lowercased"
    true
  end

  private

  Harness = Struct.new(:command, :wirings, :events, :out, :engine, :torn_down, :ui, :as_names, :factory_uis, :reach_roots, keyword_init: true) do
    # A project context carrying this harness's Ui — the terminal the command asks at.
    def build_context(name:, engine: nil, root: "/tmp/runner-test")
      Dev::Cli::ExecutionContext.new(ui: ui, project: Dev::Cli::ProjectContext.new(name: name, root: Pathname.new(root), engine: engine))
    end

    # The same, with no project (`--org`).
    def projectless_context
      Dev::Cli::ExecutionContext.new(ui: ui)
    end
  end

  # A command over recording seams: the setup factory records each
  # (config, repo, org) wiring and answers with a no-op setup; contracts
  # record their lifecycle; discovery reads a real (tmp) home; the registry
  # is the injected fake; the teardown resolves for real over that home
  # but only records what it would remove; the Ui is a RecordingUi over
  # the same `out` (plain tier, so `out.string` reads every line) each test
  # scripts (tests that say nothing tolerate no question).
  def build_harness(contracts: 0, home: Dir.mktmpdir, registry: FakeRegistry.new,
                    scope: "d3mlabs/cellbound-3d", repo: "d3mlabs/cellbound-3d", contracts_factory: nil,
                    repo_resolver: nil, runner_user: nil, data_root_provisioner: nil, wsl_runner_host: nil, reach: nil,
                    pins: [], hostname: "mac1", refresher: ->(_scope) { raise "no refresh expected" })
    wirings = []
    events = []
    torn_down = []
    as_names = []
    factory_uis = []
    reach_roots = []
    out = StringIO.new
    # A setup double per dir: the default one for a config naming none,
    # one resolving to the config's dir otherwise (a further slot's, or a
    # re-enrollment's).
    setups = Hash.new do |cache, dir|
      double = typed_mock(Dev::RunnerSetup)
      double.stubs(:run).with { events << [:run] || true }
      double.stubs(:resolve_dir).returns(dir || "/tmp/runner-dir")
      double.stubs(:resolve_name).returns(hostname)
      double.stubs(:resolve_scope).returns(scope)
      cache[dir] = double
    end
    # The engine step is a mocha mock so each test states whether it expects
    # a provision; tests that say nothing tolerate any call.
    engine = typed_mock(Dev::EngineProvisioner)
    engine.stubs(:provision!)
    discovery = Dev::RunnerDiscovery.new(home: home)
    teardown = Dev::RunnerTeardown.new(discovery: discovery, executor: nil, home: home)
    teardown.define_singleton_method(:teardown!) { |enrollment, ui:| torn_down << enrollment }
    ui = RecordingUi.new(out: out)
    command = Dev::Cli::Builtins::RunnerRegisterCommand.new(
      runner_setup_factory: ->(config, repo_override, org, as_user, ui) {
        wirings << [config, repo_override, org, as_user, ui]
        setups[config.dir]
      },
      # The host rule's seam: nil is a Mac (no runner user); a test on the
      # Linux rule injects one and sees what --as named and which Ui the
      # user was handed to speak on.
      runner_user_factory: ->(name, ui) {
        as_names << name
        factory_uis << ui
        runner_user
      },
      data_root_provisioner: data_root_provisioner,
      # The WSL runner host (dev#261): nil is any host but a WSL2 distro.
      wsl_runner_host: wsl_runner_host,
      # The lock as the reach check reads it, and the check itself.
      pins_reader: ->(root) {
        reach_roots << root
        pins
      },
      reach_factory: ->(_identity) { reach || Dev::HostReach.new(identity: runner_user, executor: nil) },
      # What `gh repo view` would answer for the enclosing checkout, unless overridden.
      repo_resolver: repo_resolver || ->(override) { override || repo },
      contracts_factory: contracts_factory || ->(_labels, _agent_user, _runner_user, _ui) {
        Array.new(contracts) { RecordedContract.new(events) }
      },
      discovery: discovery,
      registry: registry,
      teardown: teardown,
      engine_provisioner: engine,
      refresher: refresher,
    )
    Harness.new(command: command, wirings: wirings, events: events, out: out, engine: engine,
      torn_down: torn_down, ui: ui, as_names: as_names, factory_uis: factory_uis, reach_roots: reach_roots)
  end

  # A .runner record the way config.sh writes it (UTF-8 BOM + JSON).
  def write_runner(home, dir_name, scope:, name:)
    dir = File.join(home, dir_name)
    FileUtils.mkdir_p(dir)
    record = { "agentName" => name, "gitHubUrl" => "https://github.com/#{scope}" }
    File.write(File.join(dir, ".runner"), "\uFEFF#{JSON.generate(record)}")
    dir
  end

  # The orchestrator pool as plans#55 enrolled it on the box: `count` slots
  # in `actions-runner-ai-orchestrator[-n]` named `<hostname>[-n]`, each
  # known to GitHub as an online orchestrator. Returns the registry's map.
  def pool_runners(home, count:, hostname:)
    (1..count).to_h do |slot|
      suffix = slot == 1 ? "" : "-#{slot}"
      write_runner(home, "actions-runner-ai-orchestrator#{suffix}", scope: "d3mlabs", name: "#{hostname}#{suffix}")
      [["d3mlabs", "#{hostname}#{suffix}"], Dev::RunnerRegistry::Runner.new(id: slot, custom_labels: ["ai-orchestrator"], status: "online")]
    end
  end

  # The runner user as register sees it: a name and a home; the converge
  # and login steps are mocha expectations each test may script (silent
  # tests tolerate any call).
  def runner_user_mock(name:, home:)
    runner_user = typed_mock(Dev::RunnerUser)
    runner_user.stubs(:name).returns(name)
    runner_user.stubs(:home).returns(home)
    runner_user.stubs(:path).returns("/opt/brew/bin:/usr/bin")
    runner_user.stubs(:converge!)
    runner_user.stubs(:ensure_gh_authenticated!)
    runner_user
  end

  # For a command built without a harness: a context whose Ui is never asked.
  def build_context(name:, engine: nil, root: "/tmp/runner-test")
    Dev::Cli::ExecutionContext.new(
      ui: RecordingUi.new,
      project: Dev::Cli::ProjectContext.new(name: name, root: Pathname.new(root), engine: engine),
    )
  end

  # A checkout whose lock pins one image: the container fact, as the
  # commands read it (ProjectImages#containerized?).
  def image_checkout
    root = Dir.mktmpdir("runner-image-checkout")
    pin = Dev::Deps::Dependency.new(
      name: "snappy-linux", integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}",
      metadata: {
        "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platform" => "linux/amd64",
        "platforms" => ["linux/amd64"], "registry" => "ghcr.io/d3mlabs", "apt" => [],
      },
    )
    Dev::Deps::Lockfile.new(dir: Pathname(root)).lock(Dev::EnvironmentImage.stamp([pin]))
    root
  end

  def projectless_context
    Dev::Cli::ExecutionContext.new(ui: RecordingUi.new)
  end
end
