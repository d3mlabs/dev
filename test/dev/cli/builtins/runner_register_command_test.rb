# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/builtins/runner_register_command"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/engine_provisioner"
require "dev/engine_resources"
require "dev/enrolled_runner"
require "dev/environment_image"
require "dev/host_reach"
require "dev/job_gh_token"
require "dev/job_identity"
require "dev/lifecycle/project_version"
require "dev/runner_discovery"
require "dev/runner_registry"
require "dev/runner_role"
require "dev/runner_role_aliases"
require "dev/runner_setup"
require "dev/runner_setup_config"
require "dev/runner_teardown"
require "dev/retired_job_hook"
require "dev/runner_user"
require "dev/wsl_runner_host"
require "etc"
require "fileutils"
require "json"
require "pathname"
require "stringio"
require "support/recording_ui"
require "tmpdir"

# The GitHub-side registry seam: answers find from a canned map and
# records amends; knows an org's runner groups ([org, name] => Group;
# every org has an unpinned Default open to all repos unless a test says
# otherwise), which group each runner id sits in, each group's selected
# repos, and the repos themselves (private, with a derived id, unless
# named) — and records every group write.
class FakeRegistry
  attr_reader :amends, :group_writes

  # The pins the alias roles carry: ai-flow's workflows at @main.
  PINS = Dev::RunnerRoleAliases::WORKFLOWS_AT_MAIN

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

  # The agent alias's labels — what `--ai-flow` still enrolls for one release.
  AGENT_LABELS = Dev::RunnerRoleAliases::AGENT.labels
  # Yesterday's agent vocabulary, one label short: drift within the family
  # (the set still shares labels with the role), amended in place.
  STALE_AGENT_LABELS = AGENT_LABELS.take(AGENT_LABELS.length - 1)
  # A dev.yml role of a checkout's own, with a job identity but no group:
  # repo-scoped, its jobs run as `ue-builder`.
  FARM = Dev::RunnerRole::Declaration.new(name: "ue-farm", labels: %w[ue gpu], job_identity: "ue-builder")
  # A checkout's reference to ai-flow's agent role (dev#701), the lock pin
  # it is read at, and the role as the declaring repo's dev.yml at that
  # version gives it, at repo scope.
  AGENT_REFERENCE = Dev::RunnerRole::Reference.new(name: "agent", declaring_repo: "d3mlabs/ai-flow")
  AI_FLOW_PIN = Dev::Deps::Dependency.new(
    name: "ai-flow", integration: :gh, group: :app, version: "2.4.1", hash: nil, metadata: { "repo" => "d3mlabs/ai-flow" },
  )
  REFERENCED_AGENT = Dev::RunnerRole::Declaration.new(
    name: "agent", labels: AGENT_LABELS, group: "ai-flow", workflows: [".github/workflows/ai-commands.yml"], job_identity: "ai-agent",
  ).as_referenced

  # Class methods, defined ahead of the tests: Where tables are evaluated
  # in class scope as the file loads.
  class << self
    # The runner user a host handed to `ci` resolves (RunnerUser.for_host),
    # as register's usage reads it: a name, no host probed.
    def ci_identity
      Dev::RunnerUser.new(name: "ci", home_of: ->(_user) { nil }, brew: nil, path: "/usr/bin", tap: nil, operator: "human")
    end
  end

  # --- usage ------------------------------------------------------------

  test "every flag register declares carries a description, so `dev runner register --help` explains each" do
    Given "the command as the CLI builds it, its host seams answered off"
    command = usage_command

    Expect "no flag lists by name alone"
    command.flags.all? { |flag| !flag.desc.empty? }
    command.flags.map(&:name) == [
      "--org", "--role", "--labels", "--ai-flow", "--slots", "--group",
      "--dir", "--name", "--repo", "--as", "--yes"
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
    config == Dev::RunnerSetupConfig.new(role: Dev::RunnerRole.build_host(labels: [label]))
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
    harness = build_harness

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
    harness = build_harness(registry: registry, scope: "d3mlabs", runner_user: fake_runner_user(name: "runner", home: "/home/runner"))

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ai-orchestrator"]), context: harness.projectless_context)

    Then "refused, naming the fix; no contract converged, no runner user touched, nothing enrolled"
    _ * harness.ui.confirm >> false
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

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ai-orchestrator"]), context: harness.projectless_context)

    Then
    _ * harness.ui.confirm >> true
    refreshed == ["admin:org"]
    harness.wirings.last.first.labels == "ai-orchestrator"
  end

  # dev#657: `--ai-flow` and `--labels ai-orchestrator` stand for ai-flow's
  # own roles for one release more, pinned at @main; each warns, naming
  # the register run from an ai-flow checkout that replaces it.
  test "--org --ai-flow is one release's alias for the agent role: the full label set, the ai-flow group, the ai-agent identity — and a warning naming its replacement" do
    Given "a harness"
    harness = build_harness

    When "registering the org agent host"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow"]), context: harness.projectless_context)

    Then "the alias role, enrolled at the org; its job identity converged; the warning first"
    config, _repo, org = harness.wirings.fetch(0)
    config.role == Dev::RunnerRoleAliases::AGENT
    config.labels == AGENT_LABELS.join(",")
    !config.labels.include?("ai-orchestrator")
    org == true
    harness.identities == [["ai-agent", nil, harness.ui]]
    harness.ui.rows.fetch(0) == [:note, "{{yellow:#{Dev::RunnerRoleAliases.warning(Dev::RunnerRoleAliases::AGENT, flag: "--ai-flow")}}}", 0]
    harness.out.string.include?("--ai-flow is an alias for the agent role ai-flow's dev.yml declares, pinned at @main; it goes away next release")
    harness.out.string.include?("dev runner register --org --role agent")
  end

  test "--org --labels ai-orchestrator --slots 2 is the orchestrator alias: a thin pool in its own open group — created when missing, nothing admitted — with no job identity (plans#53, dev#495)" do
    Given "an org with the pinned ai-flow group and no orchestrator group yet"
    registry = FakeRegistry.new(groups: { ["d3mlabs", "ai-flow"] => FakeRegistry.group(id: 7, name: "ai-flow", pinned: true) })
    harness = build_harness(registry: registry, scope: "d3mlabs")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ai-orchestrator", "--slots", "2"]), context: harness.projectless_context)

    Then "two slots named <host>-orchestrator[-n] carrying the label, in the ai-orchestrator group, which was created open to every repo and pinned; no selection written; no identity asked for; the alias warned"
    harness.wirings.drop(1).map { |config, _repo, _org| config.labels } == ["ai-orchestrator", "ai-orchestrator"]
    harness.wirings.drop(1).map { |config, _repo, _org| config.group } == ["ai-orchestrator", "ai-orchestrator"]
    harness.wirings.drop(1).map { |config, _repo, _org| config.name } == ["mac1-orchestrator", "mac1-orchestrator-2"]
    registry.group_writes == [[:create, "d3mlabs", "ai-orchestrator", "all", true, FakeRegistry::PINS]]
    harness.out.string.include?("may use group 'ai-orchestrator' (open to every repo at d3mlabs)")
    harness.identities == []
    harness.events == [[:run], [:run]]
    harness.out.string.include?("--labels ai-orchestrator is an alias for the orchestrator role")
  end

  test "--labels mixing an agent label with ai-orchestrator is a custom set like any other now: dev knows no ai-flow vocabulary beyond the two aliases" do
    Given
    harness = build_harness(scope: "d3mlabs")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ai-build,ai-orchestrator"]), context: harness.projectless_context)

    Then "a build host in Default carrying the set as typed; no identity, no warning"
    config = harness.wirings.fetch(0).fetch(0)
    config.role == Dev::RunnerRole.build_host(labels: %w[ai-build ai-orchestrator])
    config.group.nil?
    harness.identities == []
    harness.ui.rows.none? { |_kind, text, _depth| text.include?("alias") }
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
    config == Dev::RunnerSetupConfig.new(role: Dev::RunnerRole.build_host(labels: ["ue-engine"]), dir: "~/actions-runner-ue", name: "gaming-box")
    repo == "d3mlabs/unreal-engine"
    org == true
  end

  # --- the idempotent converge ----------------------------------------

  test "a fresh scope runs the full enrollment for a role with a job identity: converge -> enroll -> after_enroll" do
    Given "no local enrollment serves the scope; the checkout declares ue-farm, whose jobs run as ue-builder"
    harness = build_harness
    context = harness.build_context(name: "Cellbound3D", runner_roles: { "ue-farm" => FARM })

    When "registering"
    harness.command.call(args: parsed_args(harness.command, ["--role", "ue-farm"]), context: context)

    Then "the ceremony runs end to end with the enrolled dir, the identity the declaration names"
    harness.identities == [["ue-builder", nil, harness.ui]]
    harness.events == [
      [:converge],
      [:run],
      [:after_enroll, "/tmp/runner-dir", 1],
    ]
  end

  test "a build host has no job identity: its jobs run as the enrolling user, so nothing converges but the enrollment" do
    Given "no local enrollment serves the scope"
    harness = build_harness

    When "registering the checkout's build host"
    harness.command.call(args: no_args, context: harness.build_context(name: "Cellbound3D"))

    Then
    harness.identities == []
    harness.events == [[:run]]
  end

  test "an enrolled scope with drifted labels is amended in place, never re-enrolled" do
    Given "this host already serves the org, with yesterday's label set (one label short), in a repo-named dir"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs", name: "mac-box", agent_id: 42)
    registry = FakeRegistry.new(
      runners: { ["d3mlabs", "mac-box"] => Dev::RunnerRegistry::Runner.new(id: 42, custom_labels: STALE_AGENT_LABELS, status: "online") },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs")

    When "registering the agent host"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow"]), context: harness.projectless_context)

    Then "one label amend; the service and dir stay put; the identity still converges"
    registry.amends == [["d3mlabs", 42, AGENT_LABELS]]
    harness.events == [
      [:converge],
      [:after_enroll, dir, 1],
    ]
  end

  test "an enrolled scope with current labels is a no-op amend" do
    Given "the enrollment already advertises the desired set"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs/cellbound-3d", name: "box", agent_id: 7)
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

  test "a local enrollment GitHub has lost re-enrolls into the same dir — its record names no pool, so whichever role registers takes it over" do
    Given "a .runner record in Default whose runner is gone server-side"
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
    legacy = write_runner(home, "actions-runner", scope: "JPDuchesne/snappy", name: "JPSFF", agent_id: 9)
    File.write(File.join(legacy, ".service"), "unit\n")
    newer = write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF", agent_id: 9)
    registry = FakeRegistry.new(
      runners: { ["JPDuchesne/snappy", "JPSFF"] => Dev::RunnerRegistry::Runner.new(id: 9, custom_labels: ["snappy"], status: "online") },
    )
    harness = build_harness(home: home, registry: registry, scope: "JPDuchesne/snappy", repo: "JPDuchesne/snappy")

    When "registering in the snappy checkout"
    harness.command.call(args: no_args, context: harness.build_context(name: "snappy"))

    Then "both are torn down, then the fresh ceremony runs into the default (label-derived) dir"
    1 * harness.ui.confirm("Unregister these and enroll fresh?") >> true
    harness.torn_down.map(&:dir) == [legacy, newer]
    harness.events == [[:run]]
    harness.wirings.last.fetch(0) == Dev::RunnerSetupConfig.new(role: Dev::RunnerRole.build_host(labels: ["snappy"]))
    registry.amends == []
    harness.ui.rows.reject { |row| row.fetch(0) == :frame }.first(3) == [
      [:note, "{{x}} JPDuchesne/snappy has 2 local enrollments named 'JPSFF' — the enrollment on disk is not what should be serving GitHub:", 0],
      [:note, "    ~/actions-runner (service installed)", 0],
      [:note, "    ~/actions-runner-snappy (no service)", 0],
    ]
  end

  test "one local enrollment whose runner GitHub lists offline: register asks; --yes answers for it" do
    Given "a registration nothing is running"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF", agent_id: 9)
    registry = FakeRegistry.new(
      runners: { ["JPDuchesne/snappy", "JPSFF"] => Dev::RunnerRegistry::Runner.new(id: 9, custom_labels: ["snappy"], status: "offline") },
    )
    harness = build_harness(home: home, registry: registry, scope: "JPDuchesne/snappy", repo: "JPDuchesne/snappy")

    When "registering with --yes"
    harness.command.call(args: parsed_args(harness.command, ["--yes"]), context: harness.build_context(name: "snappy"))

    Then "no prompt; torn down and enrolled fresh; nothing amended"
    0 * harness.ui.confirm
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

    When "registering"
    harness.command.call(args: no_args, context: harness.build_context(name: "snappy"))

    Then "the refusal is the error the CLI maps to exit 1, carrying the remedy; nothing ran"
    1 * harness.ui.confirm >> false
    error = raises Dev::Cli::Builtins::RunnerRegisterCommand::SupersededEnrollmentsError
    error.message.include?("dev runner unregister ~/actions-runner\n")
    error.message.include?("dev runner unregister ~/actions-runner-snappy")
    harness.torn_down == []
    harness.events == []
  end

  test "one local enrollment, online: the amend path, no question asked" do
    Given "the steady state"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF", agent_id: 9)
    registry = FakeRegistry.new(
      runners: { ["JPDuchesne/snappy", "JPSFF"] => Dev::RunnerRegistry::Runner.new(id: 9, custom_labels: ["snappy"], status: "online") },
    )
    harness = build_harness(home: home, registry: registry, scope: "JPDuchesne/snappy", repo: "JPDuchesne/snappy")

    When "registering"
    harness.command.call(args: no_args, context: harness.build_context(name: "snappy"))

    Then
    0 * harness.ui.confirm
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

    When "registering with an explicit dir"
    harness.command.call(args: parsed_args(harness.command, ["--dir", "~/actions-runner-other"]), context: harness.build_context(name: "snappy"))

    Then
    0 * harness.ui.confirm
    harness.torn_down == []
    harness.events == [[:run]]
  end

  test "--dir skips discovery: the dir is the operator's to pick" do
    Given "an enrollment discovery would have found"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs", name: "mac-box", agent_id: 42)
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

  test "--slots 3 on a fresh scope enrolls three slots named from the role: <host>-agent, then -2 and -3 beside it" do
    Given "no enrollment at the org, a host named mac1"
    harness = build_harness(scope: "d3mlabs", hostname: "mac1")

    When "registering the agent host with three slots"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow", "--slots", "3"]), context: harness.projectless_context)

    Then "one converge, then three enrollments, each followed by its after_enroll; every slot is named from <host>-agent and placed from slot 1's dir"
    harness.events == [
      [:converge],
      [:run], [:after_enroll, "/tmp/runner-dir", 1],
      [:run], [:after_enroll, "/tmp/runner-dir-2", 2],
      [:run], [:after_enroll, "/tmp/runner-dir-3", 3],
    ]
    harness.wirings.drop(1).map(&:first) == [
      Dev::RunnerSetupConfig.new(role: Dev::RunnerRoleAliases::AGENT, dir: "/tmp/runner-dir", name: "mac1-agent"),
      Dev::RunnerSetupConfig.new(role: Dev::RunnerRoleAliases::AGENT, dir: "/tmp/runner-dir-2", name: "mac1-agent-2"),
      Dev::RunnerSetupConfig.new(role: Dev::RunnerRoleAliases::AGENT, dir: "/tmp/runner-dir-3", name: "mac1-agent-3"),
    ]
  end

  test "--slots 3 over a one-slot enrollment amends slot 1 in place and adds slots 2 and 3 beside its dir" do
    Given "a host already serving the org with one online agent runner (yesterday's labels), in a dir of its own naming"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs", name: "mac-box", agent_id: 42)
    registry = FakeRegistry.new(
      runners: { ["d3mlabs", "mac-box"] => Dev::RunnerRegistry::Runner.new(id: 42, custom_labels: STALE_AGENT_LABELS, status: "online") },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs")

    When "growing to three"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow", "--slots", "3"]), context: harness.projectless_context)

    Then "slot 1 is amended, not re-enrolled; the new slots take slot 1's base (the enrollment's name) and sit beside its dir"
    0 * harness.ui.confirm
    registry.amends == [["d3mlabs", 42, AGENT_LABELS]]
    harness.events == [
      [:converge],
      [:after_enroll, dir, 1],
      [:run], [:after_enroll, "#{dir}-2", 2],
      [:run], [:after_enroll, "#{dir}-3", 3],
    ]
    harness.wirings.drop(1).map(&:first) == [
      Dev::RunnerSetupConfig.new(role: Dev::RunnerRoleAliases::AGENT, dir: "#{dir}-2", name: "mac-box-2"),
      Dev::RunnerSetupConfig.new(role: Dev::RunnerRoleAliases::AGENT, dir: "#{dir}-3", name: "mac-box-3"),
    ]
    harness.torn_down == []
  end

  test "re-running without --slots keeps the slot count: every slot amended, nothing added or retired" do
    Given "two slots, both online with stale labels"
    home = Dir.mktmpdir
    one = write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1", agent_id: 1)
    two = write_runner(home, "actions-runner-ai-ask-2", scope: "d3mlabs", name: "mac1-2", agent_id: 2)
    registry = FakeRegistry.new(
      runners: {
        ["d3mlabs", "mac1"] => Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-ask"], status: "online"),
        ["d3mlabs", "mac1-2"] => Dev::RunnerRegistry::Runner.new(id: 2, custom_labels: ["ai-ask"], status: "online"),
      },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs")

    When "re-running register"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow"]), context: harness.projectless_context)

    Then
    0 * harness.ui.confirm
    registry.amends.map { |_scope, id, _labels| id } == [1, 2]
    harness.events == [[:converge], [:after_enroll, one, 1], [:after_enroll, two, 2]]
    harness.torn_down == []
  end

  test "a smaller --slots lists the surplus slots, asks, and on yes unregisters them — the kept slots are amended as usual" do
    Given "three slots, asked down to one"
    home = Dir.mktmpdir
    one = write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1", agent_id: 1)
    two = write_runner(home, "actions-runner-ai-ask-2", scope: "d3mlabs", name: "mac1-2", agent_id: 2)
    three = write_runner(home, "actions-runner-ai-ask-3", scope: "d3mlabs", name: "mac1-3", agent_id: 3)
    runners = %w[mac1 mac1-2 mac1-3].each_with_index.to_h do |name, i|
      [["d3mlabs", name], Dev::RunnerRegistry::Runner.new(id: i + 1, custom_labels: AGENT_LABELS, status: "online")]
    end
    registry = FakeRegistry.new(runners: runners)
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs")

    When "shrinking"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow", "--slots", "1"]), context: harness.projectless_context)

    Then "slots 2 and 3 are torn down; slot 1 stays, labels current"
    1 * harness.ui.confirm("Unregister them?") >> true
    harness.torn_down.map(&:dir) == [two, three]
    harness.enrollments == []
    registry.amends == []
    harness.out.string.include?("2 more slots than asked for")
    harness.out.string.include?("mac1-2 (~/actions-runner-ai-ask-2)")
    File.directory?(one)
  end

  test "declining the shrink changes nothing and names the unregister commands" do
    Given "two slots, asked down to one, and an operator who says no"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1", agent_id: 1)
    write_runner(home, "actions-runner-ai-ask-2", scope: "d3mlabs", name: "mac1-2", agent_id: 2)
    registry = FakeRegistry.new(
      runners: {
        ["d3mlabs", "mac1"] => Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-ask"], status: "online"),
        ["d3mlabs", "mac1-2"] => Dev::RunnerRegistry::Runner.new(id: 2, custom_labels: ["ai-ask"], status: "online"),
      },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow", "--slots", "1"]), context: harness.projectless_context)

    Then
    1 * harness.ui.confirm("Unregister it?") >> false
    error = raises Dev::Cli::Builtins::RunnerRegisterCommand::SurplusSlotsError
    error.message.include?("dev runner unregister ~/actions-runner-ai-ask-2")
    harness.torn_down == []
    registry.amends == []
    harness.enrollments == []
  end

  test "a gap in the slots is re-filled: slots 1 and 3 enrolled, bare register adds slot 2" do
    Given
    home = Dir.mktmpdir
    one = write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1", agent_id: 1)
    write_runner(home, "actions-runner-ai-ask-3", scope: "d3mlabs", name: "mac1-3", agent_id: 3)
    registry = FakeRegistry.new(
      runners: {
        ["d3mlabs", "mac1"] => Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: AGENT_LABELS, status: "online"),
        ["d3mlabs", "mac1-3"] => Dev::RunnerRegistry::Runner.new(id: 3, custom_labels: AGENT_LABELS, status: "online"),
      },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow"]), context: harness.projectless_context)

    Then
    harness.enrollments == [[:run]]
    harness.wirings.last.first == Dev::RunnerSetupConfig.new(role: Dev::RunnerRoleAliases::AGENT, dir: "#{one}-2", name: "mac1-2")
  end

  test "a slot GitHub has lost re-enrolls into its own dir under its own name — its record's pool says whose it is; the rest are amended" do
    Given "two slots whose second runner is gone server-side, its .runner naming the ai-flow pool"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1", agent_id: 1)
    two = write_runner(home, "actions-runner-ai-ask-2", scope: "d3mlabs", name: "mac1-2", pool: "ai-flow")
    registry = FakeRegistry.new(
      runners: { ["d3mlabs", "mac1"] => Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: AGENT_LABELS, status: "online") },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow"]), context: harness.projectless_context)

    Then
    0 * harness.ui.confirm
    harness.enrollments == [[:run]]
    harness.wirings.last.first == Dev::RunnerSetupConfig.new(role: Dev::RunnerRoleAliases::AGENT, dir: two, name: "mac1-2")
    harness.torn_down == []
  end

  # --- families: two org-scoped label sets on one host (dev#557) ----------

  test "the agent family enrolls beside the orchestrator pool at the same org scope: the pool is neither counted, amended nor retired, and the family is named from its role" do
    Given "the box: ten pool slots under the bare hostname, GitHub knowing them all as online orchestrators"
    home = Dir.mktmpdir
    registry = FakeRegistry.new(runners: pool_runners(home, count: 10, hostname: "JPSFF"))
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs", hostname: "JPSFF")

    When "registering the agent host with three slots"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow", "--slots", "3"]), context: harness.projectless_context)

    Then "three fresh slots named <hostname>-agent[-n], the pool untouched"
    0 * harness.ui.confirm
    harness.wirings.drop(1).map(&:first) == [
      Dev::RunnerSetupConfig.new(role: Dev::RunnerRoleAliases::AGENT, dir: "/tmp/runner-dir", name: "JPSFF-agent"),
      Dev::RunnerSetupConfig.new(role: Dev::RunnerRoleAliases::AGENT, dir: "/tmp/runner-dir-2", name: "JPSFF-agent-2"),
      Dev::RunnerSetupConfig.new(role: Dev::RunnerRoleAliases::AGENT, dir: "/tmp/runner-dir-3", name: "JPSFF-agent-3"),
    ]
    harness.events == [
      [:converge],
      [:run], [:after_enroll, "/tmp/runner-dir", 1],
      [:run], [:after_enroll, "/tmp/runner-dir-2", 2],
      [:run], [:after_enroll, "/tmp/runner-dir-3", 3],
    ]
    harness.torn_down == []
    registry.amends == []
    !harness.out.string.include?("more slots than asked for")
  end

  test "re-running the agent family beside the pool is a no-op on both: its own slots are amended under the names they have, the pool's never named" do
    Given "the pool and a three-slot agent family under the box's pre-role base, all online and current"
    home = Dir.mktmpdir
    runners = pool_runners(home, count: 10, hostname: "JPSFF")
    %w[JPSFF-ai-ask JPSFF-ai-ask-2 JPSFF-ai-ask-3].each_with_index do |name, i|
      write_runner(home, "actions-runner-ai-ask#{"-#{i + 1}" if i.positive?}", scope: "d3mlabs", name: name, agent_id: 100 + i, pool: "ai-flow")
      runners[["d3mlabs", name]] = Dev::RunnerRegistry::Runner.new(id: 100 + i, custom_labels: AGENT_LABELS, status: "online")
    end
    registry = FakeRegistry.new(runners: runners)
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs", hostname: "JPSFF")

    When "re-running without --slots"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow"]), context: harness.projectless_context)

    Then "three after_enrolls, nothing run, nothing torn down, no surplus"
    0 * harness.ui.confirm
    harness.events.map(&:first) == [:converge, :after_enroll, :after_enroll, :after_enroll]
    harness.torn_down == []
    registry.amends == []
    !harness.out.string.include?("more slots than asked for")
  end

  test "the reverse order: the pool enrolls beside an agent family holding the hostname, named from its role, and a smaller --slots never counts the family's slots as surplus" do
    Given "a two-slot agent family under the bare hostname"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1", agent_id: 1)
    write_runner(home, "actions-runner-ai-ask-2", scope: "d3mlabs", name: "mac1-2", agent_id: 2)
    registry = FakeRegistry.new(
      runners: {
        ["d3mlabs", "mac1"] => Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: AGENT_LABELS, status: "online"),
        ["d3mlabs", "mac1-2"] => Dev::RunnerRegistry::Runner.new(id: 2, custom_labels: AGENT_LABELS, status: "online"),
      },
      groups: { ["d3mlabs", "ai-flow"] => FakeRegistry.group(id: 7, name: "ai-flow", pinned: true) },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs", hostname: "mac1")

    When "enrolling a one-slot pool"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ai-orchestrator", "--slots", "1"]), context: harness.projectless_context)

    Then
    0 * harness.ui.confirm
    harness.wirings.last.first == Dev::RunnerSetupConfig.new(role: Dev::RunnerRoleAliases::ORCHESTRATOR, dir: "/tmp/runner-dir", name: "mac1-orchestrator")
    harness.events == [[:run]]
    harness.torn_down == []
    registry.amends == []
  end

  test "a pool slot GitHub has lost is still the pool's — its .runner record names the pool — not a stranger for the agent family to retire" do
    Given "the pool with one slot gone server-side, and no agent family yet"
    home = Dir.mktmpdir
    runners = pool_runners(home, count: 3, hostname: "JPSFF")
    runners.delete(["d3mlabs", "JPSFF-3"])
    registry = FakeRegistry.new(runners: runners)
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs", hostname: "JPSFF")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow"]), context: harness.projectless_context)

    Then "one fresh agent slot under its role's name; nothing retired"
    0 * harness.ui.confirm
    harness.wirings.last.first == Dev::RunnerSetupConfig.new(role: Dev::RunnerRoleAliases::AGENT, dir: "/tmp/runner-dir", name: "JPSFF-agent")
    harness.torn_down == []
    !harness.out.string.include?("none of this host's slots")
  end

  test "an enrollment at the scope that is none of this host's slots — another name — is superseded like a leftover: listed, asked about, retired, then the slots enroll fresh" do
    Given "one of this host's slots and an enrollment under a name that is nobody's slot"
    home = Dir.mktmpdir
    mine = write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1", agent_id: 1)
    other = write_runner(home, "actions-runner-old", scope: "d3mlabs", name: "old-box", agent_id: 9)
    registry = FakeRegistry.new(
      runners: {
        ["d3mlabs", "mac1"] => Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-ask"], status: "online"),
        ["d3mlabs", "old-box"] => Dev::RunnerRegistry::Runner.new(id: 9, custom_labels: ["ai-ask"], status: "online"),
      },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs", hostname: "mac1")

    When "registering as mac1 with two slots"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow", "--name", "mac1", "--slots", "2"]), context: harness.projectless_context)

    Then
    1 * harness.ui.confirm("Unregister these and enroll fresh?") >> true
    harness.torn_down.map(&:dir).sort == [mine, other].sort
    harness.out.string.include?("an enrollment named 'old-box' that is none of this host's slots")
    harness.enrollments == [[:run], [:run]]
  end

  # --- never steal a registration (dev#565) --------------------------------

  test "a fresh family at a scope where GitHub holds its role's name for another registration — no dir of this host's — refuses, naming the holder, and changes nothing: --replace would have taken the registration over" do
    Given "GitHub listing an online runner under this host's agent name at the org (another box with this hostname), and no local enrollment at all"
    registry = FakeRegistry.new(runners: { ["d3mlabs", "JPSFF-agent"] => Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: ["ai-orchestrator"], status: "online") })
    harness = build_harness(home: Dir.mktmpdir, registry: registry, scope: "d3mlabs", hostname: "JPSFF")

    When "registering the agent host"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow"]), context: harness.projectless_context)

    Then "refused with the holder's labels and status and the way beside it; nothing enrolled, amended or torn down"
    0 * harness.ui.confirm
    raises Dev::Cli::Builtins::RunnerRegisterCommand::RegistrationHeldError
    harness.ui.rows.include?([:note, "{{x}} 'JPSFF-agent' at d3mlabs is registered by another family (labels: ai-orchestrator, online) — pass --name to enroll beside it", 0])
    harness.enrollments == []
    harness.torn_down == []
    registry.amends == []
  end

  test "--name asking for a name the other family on this host holds is refused the same way — the pool's slot is never replaced, and no slot enrolls" do
    Given "the box's pool under the bare hostname, and an agent family asked to take that name with two slots"
    home = Dir.mktmpdir
    registry = FakeRegistry.new(runners: pool_runners(home, count: 2, hostname: "JPSFF"))
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs", hostname: "JPSFF")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow", "--name", "JPSFF", "--slots", "2"]), context: harness.projectless_context)

    Then "the refusal names the pool's registration; the contract converged (host facts, not enrollment) but neither slot ran"
    0 * harness.ui.confirm
    error = raises Dev::Cli::Builtins::RunnerRegisterCommand::RegistrationHeldError
    error.message.include?("'JPSFF' at d3mlabs")
    harness.out.string.include?("'JPSFF' at d3mlabs is registered by another family (labels: ai-orchestrator, online) — pass --name to enroll beside it")
    harness.events == [[:converge]]
    harness.torn_down == []
    registry.amends == []
  end

  test "re-enrolling a family's own slot — GitHub still listing its name — passes --replace: the only registration register ever takes over" do
    Given "this family's one slot, offline on GitHub under the hostname, so register retires it and enrolls fresh under the same name"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF", agent_id: 9)
    registry = FakeRegistry.new(
      runners: { ["JPDuchesne/snappy", "JPSFF"] => Dev::RunnerRegistry::Runner.new(id: 9, custom_labels: ["snappy"], status: "offline") },
    )
    harness = build_harness(home: home, registry: registry, scope: "JPDuchesne/snappy", repo: "JPDuchesne/snappy", hostname: "JPSFF")

    When
    harness.command.call(args: parsed_args(harness.command, ["--yes"]), context: harness.build_context(name: "snappy"))

    Then "torn down, then enrolled with --replace under its own name"
    harness.torn_down.map(&:dir) == [dir]
    harness.events == [[:run]]
    harness.wirings.last.first == Dev::RunnerSetupConfig.new(role: Dev::RunnerRole.build_host(labels: ["snappy"]), dir: "/tmp/runner-dir", name: "JPSFF", replace: true)
  end

  test "own is the registration, not the name: a local enrollment whose .runner id is not the id GitHub holds under that name is another machine's look-alike — refused, the stale dir named, nothing replaced" do
    Given "this host's dir for 'mac1-agent' records id 42; GitHub's 'mac1-agent' is id 77 — another host with the same hostname enrolled after this registration was lost"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1", agent_id: 42)
    registry = FakeRegistry.new(
      runners: { ["d3mlabs", "mac1"] => Dev::RunnerRegistry::Runner.new(id: 77, custom_labels: AGENT_LABELS, status: "offline") },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs", hostname: "mac1")

    When "re-registering here (GitHub lists the name offline, so the family looks like its own superseded slot)"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow", "--yes"]), context: harness.projectless_context)

    Then "refused before anything is torn down or enrolled; the message says the local record is stale and how to clear it"
    0 * harness.ui.confirm
    raises Dev::Cli::Builtins::RunnerRegisterCommand::RegistrationHeldError
    harness.out.string.include?("'mac1' at d3mlabs is registered by another host under this family's name")
    harness.out.string.include?("this host's #{Dev::RunnerDiscovery.read(dir, home: home).display_dir} records a registration GitHub no longer holds — dev runner unregister it, then re-run")
    harness.torn_down == []
    harness.enrollments == []
    registry.amends == []
  end

  test "--dir over this host's own configured dir whose name GitHub holds re-enrolls with --replace: the dir's own record is the family, discovery or not" do
    Given "an operator-picked dir already enrolled as 'box' (id 5), which GitHub lists under that name with the same id"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-heavy", scope: "d3mlabs", name: "box", agent_id: 5)
    registry = FakeRegistry.new(
      runners: { ["d3mlabs", "box"] => Dev::RunnerRegistry::Runner.new(id: 5, custom_labels: ["ai-build"], status: "online") },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs", hostname: "box")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ai-build", "--dir", dir]), context: harness.projectless_context)

    Then "the full enrollment runs there with --replace; no refusal, no amend"
    harness.events == [[:run]]
    harness.wirings.map(&:first).last.replace == true
    registry.amends == []
  end

  test "--dir over this host's configured dir whose name GitHub now holds under another id is refused like any other collision" do
    Given "the dir records id 5; GitHub's 'box' is id 6"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-heavy", scope: "d3mlabs", name: "box", agent_id: 5)
    registry = FakeRegistry.new(
      runners: { ["d3mlabs", "box"] => Dev::RunnerRegistry::Runner.new(id: 6, custom_labels: ["ai-build"], status: "online") },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs", hostname: "box")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ai-build", "--dir", dir]), context: harness.projectless_context)

    Then
    raises Dev::Cli::Builtins::RunnerRegisterCommand::RegistrationHeldError
    harness.events == []
  end

  test "a name nothing holds at the scope enrolls without --replace, slot 1 and the slots beside it alike" do
    Given "a fresh org scope"
    harness = build_harness(scope: "d3mlabs", hostname: "mac1")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow", "--slots", "2"]), context: harness.projectless_context)

    Then
    harness.enrollments == [[:run], [:run]]
    harness.wirings.drop(1).map { |config, _repo, _org| config.replace } == [false, false]
  end

  test "--name with --slots names every slot from it — <name>, <name>-2 — never two slots under one name" do
    Given "a fresh org scope and a name of the operator's choosing"
    harness = build_harness(scope: "d3mlabs", hostname: "mac1")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow", "--name", "agents", "--slots", "2"]), context: harness.projectless_context)

    Then "slot 1 is the plain config under the name; slot 2 is named and placed from it"
    labels = AGENT_LABELS.join(",")
    harness.wirings.map(&:first) == [
      Dev::RunnerSetupConfig.new(role: Dev::RunnerRoleAliases::AGENT, name: "agents"),
      Dev::RunnerSetupConfig.new(role: Dev::RunnerRoleAliases::AGENT, dir: "/tmp/runner-dir-2", name: "agents-2"),
    ]
  end

  test "--slots #{raw.inspect} is refused before anything converges" do
    Given
    harness = build_harness

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

  AI_FLOW_SET = AGENT_LABELS.join(",")

  test "ai-flow labels oblige the ai-flow group: a fresh org registration creates it — selected, pinned to ai-flow's workflows — hands it to config.sh, and admits the checkout's repo" do
    Given "an org with no ai-flow group yet, registering from the cellbound checkout"
    registry = FakeRegistry.new
    harness = build_harness(registry: registry, scope: "d3mlabs", repo: "d3mlabs/cellbound")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow"]), context: harness.projectless_context)

    Then "created before the enrollment, the slot's config names it, the repo is selected into it (private: no public flag)"
    registry.group_writes == [
      [:create, "d3mlabs", "ai-flow", "selected", false, FakeRegistry::PINS],
      [:select, "d3mlabs", 99, ["d3mlabs/cellbound".sum]],
    ]
    harness.wirings.first.first == Dev::RunnerSetupConfig.new(role: Dev::RunnerRoleAliases::AGENT)
    harness.out.string.include?("Creating runner group 'ai-flow' at d3mlabs")
    harness.out.string.include?("Admitting d3mlabs/cellbound to group 'ai-flow'")
  end

  test "a --labels subset of the agent vocabulary is a custom set, not the alias: Default group, no identity, no warning" do
    Given
    registry = FakeRegistry.new(groups: { ["d3mlabs", "ai-flow"] => FakeRegistry.group(id: 7, name: "ai-flow", pinned: true) })
    harness = build_harness(registry: registry, scope: "d3mlabs")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ai-build"]), context: harness.projectless_context)

    Then
    harness.wirings.first.first.group.nil?
    registry.group_writes == []
    harness.identities == []
    harness.ui.rows.none? { |_kind, text, _depth| text.include?("alias") }
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
    drifted.group_writes.first == [:update, "d3mlabs", 7, "selected", nil, FakeRegistry::PINS]
    drifted.group_writes.last.first == :select
    drifted_harness.out.string.include?("drifted: visibility is 'all', not 'selected'; not restricted to workflows")
  end

  test "an amended slot sitting in another group is moved into the ai-flow group; one already there is not touched" do
    Given "one slot in Default, growing to two; the ai-flow group already sees the checkout's repo"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1", agent_id: 1)
    default = FakeRegistry.group(id: 1, name: "Default", visibility: "all")
    ai_flow = FakeRegistry.group(id: 7, name: "ai-flow", pinned: true)
    registry = FakeRegistry.new(
      runners: { ["d3mlabs", "mac1"] => Dev::RunnerRegistry::Runner.new(id: 1, custom_labels: AGENT_LABELS, status: "online") },
      groups: { ["d3mlabs", "ai-flow"] => ai_flow },
      placements: { ["d3mlabs", 1] => default },
      selections: { ["d3mlabs", 7] => [Dev::RunnerRegistry::GroupRepository.new(id: 100, full_name: "d3mlabs/cellbound-3d")] },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow", "--slots", "2"]), context: harness.projectless_context)

    Then "slot 1 moved; slot 2's config carries the group for config.sh --runnergroup"
    registry.group_writes == [[:place, "d3mlabs", 7, 1]]
    harness.wirings.last.first == Dev::RunnerSetupConfig.new(role: Dev::RunnerRoleAliases::AGENT, dir: "#{dir}-2", name: "mac1-2")
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

  test "the invariant holds for a human's group too: a build host for a public repo reaches it through any workflow, so the role's reach refuses before anything enrolls" do
    Given "ue-hosted, unpinned and selected, registered for from the public dev checkout"
    registry = FakeRegistry.new(
      groups: { ["d3mlabs", "ue-hosted"] => FakeRegistry.group(id: 3, name: "ue-hosted", pinned: false) },
      repositories: { "d3mlabs/dev" => Dev::RunnerRegistry::Repository.new(id: 100, full_name: "d3mlabs/dev", visibility: "public") },
    )
    harness = build_harness(registry: registry, scope: "d3mlabs", repo: "d3mlabs/dev")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ue-engine", "--group", "ue-hosted"]), context: harness.projectless_context)

    Then
    error = raises Dev::Reach::ExposedError
    error.message.include?("YAML could land on this host")
    registry.group_writes == []
    harness.events == []
  end

  test "--ai-flow from a user-account repo's checkout registers the agent role at the repo: no org pre-flight, no group, the setup wired repo-scoped" do
    Given "snappy, owned by a user; any org-level probe at that owner would be refused"
    snappy = Dev::RunnerRegistry::Repository.new(id: 100, full_name: "JPDuchesne/snappy", visibility: "private", owner_type: "User")
    registry = FakeRegistry.new(repositories: { "JPDuchesne/snappy" => snappy }, refused: ["JPDuchesne"])
    harness = build_harness(registry: registry, scope: "JPDuchesne/snappy", repo: "JPDuchesne/snappy")

    When
    harness.command.call(args: parsed_args(harness.command, ["--ai-flow"]), context: harness.projectless_context)

    Then "repo scope, the agent labels, the agent host contract converged, no group for config.sh, nothing written to any group"
    config, _repo, org, _as, _ui = harness.wirings.last
    org == false
    config.role == Dev::RunnerRoleAliases::AGENT.at_repo_scope
    config.group.nil?
    registry.group_writes == []
    harness.events == [[:converge], [:run], [:after_enroll, "/tmp/runner-dir", 1]]
  end

  test "--org on a user-account repo is refused before anything converges: a user has no runner groups, so the registration can only be the repo's" do
    Given
    snappy = Dev::RunnerRegistry::Repository.new(id: 100, full_name: "JPDuchesne/snappy", visibility: "private", owner_type: "User")
    harness = build_harness(registry: FakeRegistry.new(repositories: { "JPDuchesne/snappy" => snappy }), scope: "JPDuchesne", repo: "JPDuchesne/snappy")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ai-orchestrator"]), context: harness.projectless_context)

    Then
    error = raises ArgumentError
    error.message.include?("JPDuchesne is a user account")
    error.message.include?("drop --org")
    harness.events == []
    harness.wirings == []
  end

  test "--role <declared> without --org from an org repo's checkout registers at the repo: no org probe, no group converged, the setup wired repo-scoped, the declared identity converged" do
    Given "cellbound-3d declares ue-farm and keeps a slot of its own on this host; the org probe would be refused if made"
    registry = FakeRegistry.new(refused: ["d3mlabs"])
    harness = build_harness(registry: registry, scope: "d3mlabs/cellbound-3d", repo: "d3mlabs/cellbound-3d")
    context = harness.build_context(name: "Cellbound3D", runner_roles: { "ue-farm" => FARM })

    When
    harness.command.call(args: parsed_args(harness.command, ["--role", "ue-farm"]), context: context)

    Then
    config, _repo, org, _as, _ui = harness.wirings.last
    org == false
    config.role == FARM.bind(repo: "d3mlabs/cellbound-3d", version: nil)
    registry.group_writes == []
    harness.identities == [["ue-builder", nil, harness.ui]]
    harness.events == [[:converge], [:run], [:after_enroll, "/tmp/runner-dir", 1]]
  end

  # --- a role referenced from another project (dev#701) -------------------------

  test "--role <referenced> from the referencing checkout enrolls this repo's lane: the role read from the declaring repo at the lock's version, repo-scoped, no group, its identity converged" do
    Given "cellbound-3d references ai-flow's agent role and pins ai-flow at 2.4.1; the org probe would be refused if made"
    registry = FakeRegistry.new(refused: ["d3mlabs"])
    loader = FakeReferencedRoleLoader.new(AGENT_REFERENCE => REFERENCED_AGENT)
    harness = build_harness(registry: registry, scope: "d3mlabs/cellbound-3d", repo: "d3mlabs/cellbound-3d", pins: [AI_FLOW_PIN], referenced_role_loader: loader)
    root = declaring_checkout(version: "0.1.0")
    context = harness.build_context(name: "Cellbound3D", root: root, runner_roles: { "agent" => AGENT_REFERENCE })

    When
    harness.command.call(args: parsed_args(harness.command, ["--role", "agent"]), context: context)

    Then "the reference was read against this checkout's lock; the slot is this repo's, in the referenced shape (no group converged); the retired hook is cleaned as for any role; the declaring project's job identity is converged here"
    loader.loads == [[AGENT_REFERENCE, [AI_FLOW_PIN]]]
    config, _repo, org, _as, _ui = harness.wirings.last
    org == false
    config.role == REFERENCED_AGENT
    config.role.group.nil?
    registry.group_writes == []
    harness.hook_removals == ["/tmp/runner-dir"]
    harness.identities == [["ai-agent", nil, harness.ui]]
    harness.events == [[:converge], [:run], [:after_enroll, "/tmp/runner-dir", 1]]
  end

  test "a referenced role's slots are named from the role, <host>-agent then -<n>, as a declared one's are" do
    Given
    loader = FakeReferencedRoleLoader.new(AGENT_REFERENCE => REFERENCED_AGENT)
    harness = build_harness(pins: [AI_FLOW_PIN], referenced_role_loader: loader, hostname: "mac1")
    context = harness.build_context(name: "Cellbound3D", runner_roles: { "agent" => AGENT_REFERENCE })

    When
    harness.command.call(args: parsed_args(harness.command, ["--role", "agent", "--slots", "2"]), context: context)

    Then
    harness.wirings.drop(1).map(&:first) == [
      Dev::RunnerSetupConfig.new(role: REFERENCED_AGENT, dir: "/tmp/runner-dir", name: "mac1-agent"),
      Dev::RunnerSetupConfig.new(role: REFERENCED_AGENT, dir: "/tmp/runner-dir-2", name: "mac1-agent-2"),
    ]
  end

  test "--org with a referenced role is refused before anything is read or enrolled: an org pool is declared and registered by its owner" do
    Given
    loader = FakeReferencedRoleLoader.new(AGENT_REFERENCE => REFERENCED_AGENT)
    harness = build_harness(scope: "d3mlabs", pins: [AI_FLOW_PIN], referenced_role_loader: loader)
    context = harness.build_context(name: "Cellbound3D", runner_roles: { "agent" => AGENT_REFERENCE })

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--role", "agent"]), context: context)

    Then
    error = raises ArgumentError
    error.message.include?("runner role 'agent' is referenced from d3mlabs/ai-flow")
    error.message.include?("an org pool is declared and registered by its owner")
    error.message.include?("dev runner register --org --role agent` from a d3mlabs/ai-flow checkout")
    error.message.include?("drop --org")
    loader.loads == []
    harness.events == []
  end

  test "a referenced role in a checkout whose lock pins nothing from the declaring repo is refused with the reason, nothing enrolled" do
    Given "the real loader over a gh that must not be asked, and a lock without ai-flow"
    gh = Class.new do
      def capture(*argv, chdir: nil, stdin: nil)
        raise "gh asked: #{argv.inspect}"
      end
    end.new
    loader = Dev::Cli::ReferencedRoleLoader.new(executor: gh, parser: Dev::Cli::RunnerRoleParser.new)
    harness = build_harness(pins: [], referenced_role_loader: loader)
    context = harness.build_context(name: "Cellbound3D", runner_roles: { "agent" => AGENT_REFERENCE })

    When
    harness.command.call(args: parsed_args(harness.command, ["--role", "agent"]), context: context)

    Then
    error = raises Dev::RunnerRole::Reference::NotDependedOnError
    error.message.include?("this checkout's lock pins nothing from it")
    harness.events == []
  end

  test "a pinned role at a public repo at repo scope is refused like a build host, and the refusal names the scope rules" do
    Given
    dev = Dev::RunnerRegistry::Repository.new(id: 100, full_name: "d3mlabs/dev", visibility: "public")
    harness = build_harness(registry: FakeRegistry.new(repositories: { "d3mlabs/dev" => dev }), scope: "d3mlabs/dev", repo: "d3mlabs/dev")

    When
    harness.command.call(args: parsed_args(harness.command, ["--ai-flow"]), context: harness.projectless_context)

    Then
    error = raises Dev::Reach::ExposedError
    error.message.include?("d3mlabs/dev is public")
    error.message.include?("docs/runners.md#scope")
    harness.events == []
  end

  test "a public repo's own build host is refused the same way: bare register in a public checkout enrolls nothing" do
    Given
    registry = FakeRegistry.new(repositories: { "d3mlabs/dev" => Dev::RunnerRegistry::Repository.new(id: 100, full_name: "d3mlabs/dev", visibility: "public") })
    harness = build_harness(registry: registry, scope: "d3mlabs/dev", repo: "d3mlabs/dev")

    When
    harness.command.call(args: no_args, context: harness.build_context(name: "dev"))

    Then
    error = raises Dev::Reach::ExposedError
    error.message.include?("d3mlabs/dev is public")
    harness.events == []
  end

  test "--group names a human's group for a custom pool: it must exist, and the checkout's repo is admitted to it" do
    Given
    registry = FakeRegistry.new(groups: { ["d3mlabs", "ue-hosted"] => FakeRegistry.group(id: 3, name: "ue-hosted") })
    harness = build_harness(registry: registry, scope: "d3mlabs", repo: "d3mlabs/unreal-engine")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ue-engine", "--group", "ue-hosted"]), context: harness.projectless_context)

    Then
    harness.wirings.first.first == Dev::RunnerSetupConfig.new(role: Dev::RunnerRole.build_host(labels: ["ue-engine"], group: Dev::RunnerGroupContract.new(name: "ue-hosted")))
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
    ["--org", "--ai-flow", "--group", "agents"]                            | "the agent alias names its group"
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

  # --- roles: declare the role, derive the labels and the scope ---

  test "--org --ai-flow is the agent role at the org: enrolled there, in the pinned group, no exclusivity question for a repo the group already selects" do
    Given "a checkout whose repo is among the ai-flow group's repos"
    registry = FakeRegistry.new(
      groups: { ["d3mlabs", "ai-flow"] => FakeRegistry.group(id: 7, name: "ai-flow", pinned: true) },
      selections: { ["d3mlabs", 7] => [Dev::RunnerRegistry::GroupRepository.new(id: 200, full_name: "d3mlabs/Cellbound-3D")] },
    )
    harness = build_harness(registry: registry, scope: "d3mlabs")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow"]), context: harness.build_context(name: "Cellbound3D"))

    Then "the setup was wired at the org; the repo stays in the group"
    0 * harness.ui.confirm
    harness.wirings.first[2] == true
    harness.wirings.first.first.role == Dev::RunnerRoleAliases::AGENT
    registry.group_writes == []
    !harness.out.string.include?("may also use")
  end

  # dev#657: a role is what a project's dev.yml declares — `--org --role
  # <name>` from the declaring checkout converges all of it: the group,
  # pinned to the project's own workflows at its series, the labels, the
  # job identity.
  test "--org --role <grouped> from the declaring checkout enrolls at the org in the role's group, pinned to the project's workflows at v<major>, with its job identity" do
    Given "a checkout at 2.3.0 declaring a grouped ue-farm with its own workflow and identity; an org with no such group yet"
    farm = Dev::RunnerRole::Declaration.new(
      name: "ue-farm", labels: %w[ue gpu], group: "ue-farm", workflows: [".github/workflows/build.yml"], job_identity: "ue-builder",
    )
    registry = FakeRegistry.new
    harness = build_harness(registry: registry, scope: "d3mlabs", hostname: "mac1")
    context = harness.build_context(name: "Cellbound3D", root: declaring_checkout(version: "2.3.0"), runner_roles: { "ue-farm" => farm })

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--role", "ue-farm"]), context: context)

    Then "the role bound to this repo's series; the group created selected and pinned there; the repo admitted; the identity converged; no alias warning"
    config, _repo, org = harness.wirings.fetch(0)
    org == true
    config.role == farm.bind(repo: "d3mlabs/cellbound-3d", version: "2.3.0")
    config.role.group == Dev::RunnerGroupContract.new(name: "ue-farm", workflows: ["d3mlabs/cellbound-3d/.github/workflows/build.yml@refs/tags/v2"])
    harness.wirings.last.first.name == "mac1-ue-farm"
    registry.group_writes.fetch(0) == [:create, "d3mlabs", "ue-farm", "selected", false, ["d3mlabs/cellbound-3d/.github/workflows/build.yml@refs/tags/v2"]]
    harness.out.string.include?("Creating runner group 'ue-farm' at d3mlabs")
    harness.out.string.include?("Admitting d3mlabs/cellbound-3d to group 'ue-farm'")
    harness.identities == [["ue-builder", nil, harness.ui]]
    harness.events == [[:converge], [:run], [:after_enroll, "/tmp/runner-dir", 1]]
    harness.ui.rows.none? { |_kind, text, _depth| text.include?("alias") }
  end

  test "--role <grouped> without --org enrolls at the repo with no runner group — a repo has none for config.sh to find — keeping the role's labels and identity" do
    Given "ai-flow's grouped agent role, registered for another repo's own lane (--repo), from the ai-flow checkout"
    agent = Dev::RunnerRole::Declaration.new(
      name: "agent", labels: %w[ai-ask ai-build], group: "ai-flow", workflows: [".github/workflows/ai-commands.yml"], job_identity: "ai-agent",
    )
    registry = FakeRegistry.new(refused: ["d3mlabs"])
    harness = build_harness(registry: registry, scope: "d3mlabs/cellbound-3d", repo: "d3mlabs/ai-flow", hostname: "mac1")
    context = harness.build_context(name: "ai-flow", root: declaring_checkout(version: "1.0.0"), runner_roles: { "agent" => agent })

    When
    harness.command.call(args: parsed_args(harness.command, ["--role", "agent", "--repo", "d3mlabs/cellbound-3d"]), context: context)

    Then "repo scope; the config names no group; labels and identity are the role's; nothing written to any group"
    config, _repo, org = harness.wirings.fetch(0)
    org == false
    config.group.nil?
    config.role.group.nil?
    !config.role.org_scoped?
    config.role.labels == %w[ai-ask ai-build]
    config.role.job_identity == "ai-agent"
    registry.group_writes == []
    harness.identities == [["ai-agent", nil, harness.ui]]
  end

  # dev#700: hosts follow no stream. The job-started hook dev 0.9.x wrote
  # into a slot's dir (dev#658) is removed by register on every slot it
  # touches — the amended ones and the fresh ones — after the slot is
  # enrolled or amended; the one-release migration.
  test "register removes the retired job-started hook from every slot's dir, amended and fresh alike" do
    Given "a checkout at 2.3.0 declaring ue-farm; one slot already enrolled online, --slots 2"
    farm = Dev::RunnerRole::Declaration.new(name: "ue-farm", labels: %w[ue gpu])
    home = Dir.mktmpdir
    existing = write_runner(home, "actions-runner-ue-farm", scope: "d3mlabs/cellbound-3d", name: "mac1-ue-farm", agent_id: 7)
    registry = FakeRegistry.new(
      runners: { ["d3mlabs/cellbound-3d", "mac1-ue-farm"] => Dev::RunnerRegistry::Runner.new(id: 7, custom_labels: %w[ue gpu], status: "online") },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs/cellbound-3d", hostname: "mac1")
    context = harness.build_context(name: "Cellbound3D", root: declaring_checkout(version: "2.3.0"), runner_roles: { "ue-farm" => farm })

    When
    harness.command.call(args: parsed_args(harness.command, ["--role", "ue-farm", "--slots", "2"]), context: context)

    Then "the amended slot's dir and the fresh slot's dir are each cleaned; the migration was built for the host rule's user (none on a Mac)"
    harness.hook_removals == [existing, File.join(home, "actions-runner-ue-farm-2")]
    harness.hook_users == [nil]
  end

  test "the retired hook is removed whatever the role: #{what}" do
    Given "a checkout declaring ue-farm"
    farm = Dev::RunnerRole::Declaration.new(name: "ue-farm", labels: %w[ue gpu])
    harness = build_harness(scope: "d3mlabs/cellbound-3d", hostname: "mac1")
    context = harness.build_context(name: "Cellbound3D", root: declaring_checkout(version: "2.3.0"), runner_roles: { "ue-farm" => farm })

    When
    harness.command.call(args: parsed_args(harness.command, args), context: context)

    Then "the one slot's dir is cleaned"
    harness.hook_removals == ["/tmp/runner-dir"]

    Where
    what              | args
    "a declared role" | ["--role", "ue-farm"]
    "the build host"  | []
  end

  test "on the Linux rule the migration is built to write as the runner user, the enrollments' owner" do
    Given "a Linux host whose runner user is ci"
    runner_user = fake_runner_user(name: "ci", home: Dir.mktmpdir)
    harness = build_harness(runner_user: runner_user, scope: "d3mlabs/cellbound-3d")

    When
    harness.command.call(args: no_args, context: harness.build_context(name: "Cellbound3D"))

    Then
    harness.hook_users == [runner_user]
  end

  # The jobs' gh credential on a host whose enrollments are the operator's
  # own (JobGhToken): the keychain login is unreadable from the runner
  # service, so register gives every slot it touches `GH_TOKEN` in its
  # `.env` — after the slot is enrolled or amended, after the hook is
  # cleaned. On the Linux rule the runner user's own login is the
  # credential, and nothing is asked.
  test "on a Mac register ensures the jobs' gh token on every slot's dir, amended and fresh alike, after the retired hook is cleaned" do
    Given "one slot already enrolled online, --slots 2"
    farm = Dev::RunnerRole::Declaration.new(name: "ue-farm", labels: %w[ue gpu])
    home = Dir.mktmpdir
    existing = write_runner(home, "actions-runner-ue-farm", scope: "d3mlabs/cellbound-3d", name: "mac1-ue-farm", agent_id: 7)
    registry = FakeRegistry.new(
      runners: { ["d3mlabs/cellbound-3d", "mac1-ue-farm"] => Dev::RunnerRegistry::Runner.new(id: 7, custom_labels: %w[ue gpu], status: "online") },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs/cellbound-3d", hostname: "mac1")
    context = harness.build_context(name: "Cellbound3D", root: declaring_checkout(version: "2.3.0"), runner_roles: { "ue-farm" => farm })

    When
    harness.command.call(args: parsed_args(harness.command, ["--role", "ue-farm", "--slots", "2"]), context: context)

    Then "each dir was given the token, once the hook was cleaned; one token object served the family, speaking on the command's Ui"
    fresh = File.join(home, "actions-runner-ue-farm-2")
    harness.token_ensured == [existing, fresh]
    harness.hook_removals == [existing, fresh]
    harness.slot_order == [[:hook, existing], [:token, existing], [:hook, fresh], [:token, fresh]]
    harness.token_uis == [harness.ui]
  end

  test "on the Linux rule no job token is built: the runner user's login is the credential" do
    Given
    runner_user = fake_runner_user(name: "ci", home: Dir.mktmpdir)
    harness = build_harness(runner_user: runner_user, scope: "d3mlabs/cellbound-3d")

    When
    harness.command.call(args: no_args, context: harness.build_context(name: "Cellbound3D"))

    Then
    harness.token_uis == []
    harness.token_ensured == []
  end

  test "a grouped role whose checkout keeps no VERSION is refused before anything converges: the pin has no series to take" do
    Given
    farm = Dev::RunnerRole::Declaration.new(name: "ue-farm", labels: %w[ue gpu], group: "ue-farm", workflows: [".github/workflows/build.yml"])
    harness = build_harness(scope: "d3mlabs")
    context = harness.build_context(name: "Cellbound3D", root: Dir.mktmpdir, runner_roles: { "ue-farm" => farm })

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--role", "ue-farm"]), context: context)

    Then
    error = raises Dev::RunnerRole::DeclarationError
    error.message.include?("keeps no VERSION")
    harness.events == []
    harness.wirings == []
  end

  test "--org --role #{name} outside a project is refused: agent and orchestrator are no longer builtins, a role is a dev.yml declaration" do
    Given
    harness = build_harness(scope: "d3mlabs", hostname: "mac1")

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--role", name]), context: harness.projectless_context)

    Then
    error = raises ArgumentError
    error.message.include?("runner role '#{name}' is not declared in a dev.yml")
    harness.wirings == []

    Where
    name           | _
    "agent"        | nil
    "orchestrator" | nil
  end

  test "--role names a dev.yml role: repo-scoped, its declared labels, named <host>-<role> and placed in actions-runner-<role>" do
    Given "a checkout declaring ue-farm"
    farm = Dev::RunnerRole::Declaration.new(name: "ue-farm", labels: %w[ue gpu])
    harness = build_harness(hostname: "mac1")
    context = harness.build_context(name: "Cellbound3D", runner_roles: { "ue-farm" => farm })

    When
    harness.command.call(args: parsed_args(harness.command, ["--role", "ue-farm"]), context: context)

    Then "a role naming no identity converges none"
    harness.wirings.first.first == Dev::RunnerSetupConfig.new(role: farm.bind(repo: "d3mlabs/cellbound-3d", version: nil))
    harness.wirings.first[2] == false
    harness.wirings.last.first.name == "mac1-ue-farm"
    harness.wirings.last.first.labels == "ue,gpu"
    harness.identities == []
  end

  test "#{words.join(" ")} is refused before anything converges: #{why}" do
    Given
    harness = build_harness
    farm = Dev::RunnerRole::Declaration.new(name: "ue-farm", labels: %w[ue gpu])
    context = harness.build_context(name: "Cellbound3D", runner_roles: { "ue-farm" => farm })

    When
    harness.command.call(args: parsed_args(harness.command, words), context: context)

    Then
    error = raises ArgumentError
    error.message.include?(hint)
    harness.events == []
    harness.wirings == []

    Where
    words                                  | why                                                             | hint
    ["--role", "gpu-farm"]                 | "an undeclared role is the drift path, pointed at dev.yml"      | "runner_roles: { gpu-farm: { labels: [...] } }"
    ["--role", "ue-farm", "--labels", "x"] | "a role's labels are its declaration"                           | "--role ue-farm declares the labels"
    ["--role", "agent", "--ai-flow"]       | "the alias and the role say the same thing twice"               | "--role agent declares the labels"
    ["--role", "ue-farm", "--org"]         | "org scope needs a group pinned to the project's workflows"     | "drop --org"
  end

  test "--role outside a project is refused: there is no dev.yml to declare it" do
    Given
    harness = build_harness

    When
    harness.command.call(args: parsed_args(harness.command, ["--role", "ue-farm"]), context: harness.projectless_context)

    Then
    error = raises ArgumentError
    error.message.include?("runner role 'ue-farm' is not declared in a dev.yml")
  end

  # --- the job identity -------------------------------------------------

  test "where the served repo pins an image, register brings the identity's engine up after the converge, sized from the repo's hint" do
    Given "a container repo (its lock pins an image) with an `engine:` block, declaring a role with a job identity"
    harness = build_harness
    engine = Dev::EngineResources::Hint.new(cpus: 8, memory_gib: 24)
    context = harness.build_context(name: "Cellbound3D", root: image_checkout, engine: engine, runner_roles: { "ue-farm" => FARM })

    When "registering"
    harness.command.call(args: parsed_args(harness.command, ["--role", "ue-farm"]), context: context)

    Then
    harness.events.first(3) == [[:engine, 8, 24], [:converge], [:engine_up, 8, 24, nil]]
  end

  test "the job identity frame is named for the role's identity — #{what}" do
    Given "a Mac (no host rule), a checkout declaring ue-farm (jobs as ue-builder)"
    harness = build_harness

    When "registering"
    harness.command.call(args: parsed_args(harness.command, words), context: harness.build_context(name: "Cellbound3D", runner_roles: { "ue-farm" => FARM }))

    Then "no host rule frame on a Mac; the identity frame only for a role declaring one"
    frames = harness.ui.rows.select { |row| row.fetch(0) == :frame }.map { |row| row.fetch(1) }
    frames.none? { |title| title.start_with?("Host rule") }
    frames.first(identity_frames.length) == identity_frames

    Where
    what                                        | words                  | identity_frames
    "the alias's identity"                      | ["--ai-flow"]          | ["Job identity (ai-agent)"]
    "the declaration's identity"                | ["--role", "ue-farm"]  | ["Job identity (ue-builder)"]
    "a build host: no identity, no empty frame" | []                     | []
  end

  test "register brings the engine up for the checked-out repo's hint before converging the job identity (#197)" do
    Given "a container repo with an `engine:` block and an engine provisioner that records its call"
    harness = build_harness
    resources = Dev::EngineResources::Hint.new(cpus: 8, memory_gib: 24)
    context = harness.build_context(name: "Cellbound3D", root: image_checkout, engine: resources, runner_roles: { "ue-farm" => FARM })

    When "registering"
    harness.command.call(args: parsed_args(harness.command, ["--role", "ue-farm"]), context: context)

    Then "the engine step is register's first act — same entry as `dev up`'s — then the identity"
    harness.events.first(3) == [[:engine, 8, 24], [:converge], [:engine_up, 8, 24, nil]]
  end

  test "register without a project (--org) has no hint and leaves the engine alone" do
    Given "an org registration from outside any checkout"
    harness = build_harness

    When "registering"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--labels", "ai-build"]), context: harness.projectless_context)

    Then
    harness.events.none? { |event| event.first == :engine }
  end

  test "a project whose lock pins no image registers without touching the engine" do
    Given "a plain repo"
    harness = build_harness

    When "registering"
    harness.command.call(args: no_args, context: harness.build_context(name: "Plain"))

    Then
    harness.events.none? { |event| event.first == :engine }
  end

  test "the role's job identity reaches the identity factory with the context's Ui; without a host rule (a Mac) no runner user does" do
    Given "a checkout declaring ue-farm, whose jobs run as ue-builder"
    harness = build_harness

    When "registering the role"
    harness.command.call(args: parsed_args(harness.command, ["--role", "ue-farm"]), context: harness.build_context(name: "Cellbound3D", runner_roles: { "ue-farm" => FARM }))

    Then "the declaration's user, no runner user, the Ui for the identity to speak on"
    harness.identities == [["ue-builder", nil, harness.ui]]
  end

  # plans#59: on Linux the sudoers edge is runner → job identity, so the
  # identity learns who the runner user is from the host rule register
  # converged.
  test "under the host rule, the runner user's name reaches the identity factory" do
    Given "a Linux host (a runner user)"
    harness = build_harness(runner_user: fake_runner_user(name: "runner", home: Dir.mktmpdir))

    When "registering"
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow"]), context: harness.projectless_context)

    Then
    harness.identities == [["ai-agent", "runner", harness.ui]]
  end

  # --- the host rule: a runner user on Linux (dev#310) -----------------

  test "on Linux, register converges the shared data root and the runner user, checks its gh login, then enrolls as it" do
    Given "a Linux host (the factory answers a runner user) and a fresh scope"
    runner_home = Dir.mktmpdir
    runner_user = fake_runner_user(name: "runner", home: runner_home)
    provisioner = typed_mock(Dev::LinuxDataRootProvisioner)
    harness = build_harness(runner_user: runner_user, data_root_provisioner: provisioner)
    sequence = sequence("host rule")
    # call order: the runner user joins the data root's group and the login runs as that user, so root, then user, then login is the contract
    provisioner.expects(:provision!).once.with(ui: harness.ui).in_sequence(sequence)
    runner_user.expects(:converge!).once.in_sequence(sequence)
    # The login gate asks at the terminal through the runner user's own Ui (the factory handed it the context's).
    runner_user.expects(:ensure_gh_authenticated!).once.with.in_sequence(sequence)

    When "registering a role with a job identity in the checkout"
    harness.command.call(args: parsed_args(harness.command, ["--role", "ue-farm"]), context: harness.build_context(name: "cellbound3d", runner_roles: { "ue-farm" => FARM }))

    Then "the runner user's work precedes the job identity and the enrollment; the setup is wired for the runner user; no --as was named; the user speaks on the context's Ui"
    harness.events == [[:converge], [:run], [:after_enroll, "/tmp/runner-dir", 1]]
    harness.wirings.fetch(0).fetch(3) == runner_user
    harness.as_names == [nil]
    harness.factory_uis == [harness.ui]
    # The runner user's work is framed as the host rule, the identity's as the job identity — in that order, before the enrollment's.
    harness.ui.rows.select { |row| row.fetch(0) == :frame }.first(2) == [[:frame, "Host rule (runner)", 0], [:frame, "Job identity (ue-builder)", 0]]
  end

  test "with a checkout, register checks the runner user's reach over the lock after the gh login and before any contract: unreachable refuses with the grants" do
    Given "a runner user that cannot read one of the repo's gh pins"
    runner_user = fake_runner_user(name: "runner", home: Dir.mktmpdir)
    reach = typed_mock(Dev::HostReach)
    pins = [Dev::Deps::Dependency.new(name: "ue", integration: :gh, group: "build", version: "1", hash: nil, metadata: { "repo" => "d3mlabs/unreal-engine" })]
    harness = build_harness(runner_user: runner_user, reach: reach, pins: pins)

    When
    harness.command.call(args: no_args, context: harness.build_context(name: "cellbound3d"))

    Then "the lock was read from the checkout; nothing converged or enrolled"
    1 * reach.check!(pins) >> raises(Dev::HostReach::UnreachableError, "runner cannot read d3mlabs/unreal-engine")
    error = raises Dev::HostReach::UnreachableError
    error.message.include?("d3mlabs/unreal-engine")
    harness.reach_roots == [Pathname.new("/tmp/runner-test")]
    harness.events == []
    harness.wirings == []
  end

  test "reach is not checked without a checkout (--org) or without a runner user (a Mac)" do
    Given
    reach = typed_mock(Dev::HostReach)
    org = build_harness(runner_user: fake_runner_user(name: "runner", home: Dir.mktmpdir), reach: reach)
    mac = build_harness(runner_user: nil, reach: reach)

    When
    org.command.call(args: parsed_args(org.command, ["--org", "--ai-flow"]), context: org.projectless_context)
    mac.command.call(args: no_args, context: mac.build_context(name: "cellbound3d"))

    Then
    0 * reach.check!
    org.reach_roots == []
    mac.reach_roots == []
  end

  test "--as names the runner user the host rule converges" do
    Given
    runner_user = fake_runner_user(name: "ci", home: Dir.mktmpdir)
    harness = build_harness(runner_user: runner_user)

    When
    harness.command.call(args: parsed_args(harness.command, ["--as", "ci"]), context: harness.build_context(name: "cellbound3d"))

    Then
    harness.as_names == ["ci"]
    harness.wirings.fetch(0).fetch(3) == runner_user
  end

  test "a runner user with no gh login stops register before any contract or enrollment: the error carries the login command" do
    Given
    runner_user = fake_runner_user(name: "runner", home: Dir.mktmpdir)
    harness = build_harness(runner_user: runner_user)

    When
    harness.command.call(args: no_args, context: harness.build_context(name: "cellbound3d"))

    Then
    _ * runner_user.ensure_gh_authenticated! >> raises(Dev::RunnerUser::GhLoginRequiredError, "sudo -iu runner gh auth login --with-token")
    error = raises Dev::RunnerUser::GhLoginRequiredError
    error.message.include?("gh auth login --with-token")
    harness.events == []
    harness.wirings == []
  end

  test "an enrollment owned by another user — the operator's own, from before the rule — is drift: register says whose it is, asks, tears it down and enrolls fresh as the runner user" do
    Given "an online enrollment in the operator's home, and a runner user as the rule (named so it cannot be this test's own user: hosted CI runs as `runner`)"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF", agent_id: 9)
    registry = FakeRegistry.new(
      runners: { ["JPDuchesne/snappy", "JPSFF"] => Dev::RunnerRegistry::Runner.new(id: 9, custom_labels: ["snappy"], status: "online") },
    )
    runner_user = fake_runner_user(name: "svc-runner", home: Dir.mktmpdir)
    harness = build_harness(home: home, registry: registry, scope: "JPDuchesne/snappy", repo: "JPDuchesne/snappy", runner_user: runner_user)

    When "registering in the snappy checkout"
    harness.command.call(args: no_args, context: harness.build_context(name: "snappy"))

    Then "torn down (as its owner — the teardown's business), then the fresh ceremony as the runner user; nothing amended"
    1 * harness.ui.confirm("Unregister these and enroll fresh?") >> true
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
    write_runner(runner_home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF", agent_id: 9)
    registry = FakeRegistry.new(
      runners: { ["JPDuchesne/snappy", "JPSFF"] => Dev::RunnerRegistry::Runner.new(id: 9, custom_labels: ["snappy"], status: "online") },
    )
    runner_user = fake_runner_user(name: Etc.getpwuid(Process.uid).name, home: runner_home)
    harness = build_harness(home: Dir.mktmpdir, registry: registry, scope: "JPDuchesne/snappy", repo: "JPDuchesne/snappy", runner_user: runner_user)

    When "registering"
    harness.command.call(args: no_args, context: harness.build_context(name: "snappy"))

    Then
    0 * harness.ui.confirm
    harness.torn_down == []
    harness.events == []
    harness.out.string.include?("nothing to amend")
  end

  test "on a Mac there is no runner user: no data root step, the setup wired for the invoking user" do
    Given "the factory answers nil, as RunnerUser.for_host does off Linux"
    provisioner = typed_mock(Dev::LinuxDataRootProvisioner)
    harness = build_harness(runner_user: nil, data_root_provisioner: provisioner)

    When
    harness.command.call(args: no_args, context: harness.build_context(name: "cellbound3d"))

    Then
    0 * provisioner.provision!
    harness.wirings.fetch(0).fetch(3).nil?
  end

  # --- the WSL runner host (dev#261) ------------------------------------

  test "in a WSL2 distro, register converges the WSL runner host with the checkout's engine hint, after the runner user and before the job identity" do
    Given "a Linux host in WSL: a runner user and a WSL runner host, and a checkout with an engine hint declaring a role with an identity"
    runner_user = fake_runner_user(name: "runner", home: Dir.mktmpdir)
    wsl_runner_host = typed_mock(Dev::WslRunnerHost)
    hint = Dev::EngineResources::Hint.new(cpus: 8, memory_gib: 24)
    harness = build_harness(runner_user: runner_user, wsl_runner_host: wsl_runner_host)
    sequence = sequence("wsl runner host")
    # call order: the Windows side is converged after the runner user's login, so the restart it may ask for finds a host already under the rule
    runner_user.expects(:ensure_gh_authenticated!).once.in_sequence(sequence)
    wsl_runner_host.expects(:converge!).once.with(resources: hint).in_sequence(sequence)

    When "registering in the checkout"
    harness.command.call(args: parsed_args(harness.command, ["--role", "ue-farm"]), context: harness.build_context(name: "cellbound3d", engine: hint, runner_roles: { "ue-farm" => FARM }))

    Then "the identity and the enrollment came after"
    harness.events == [[:converge], [:run], [:after_enroll, "/tmp/runner-dir", 1]]
  end

  test "the WSL runner host refusing (no interop, a restart due) stops register before any identity or enrollment" do
    Given
    wsl_runner_host = typed_mock(Dev::WslRunnerHost)
    harness = build_harness(wsl_runner_host: wsl_runner_host)

    When
    harness.command.call(args: no_args, context: harness.build_context(name: "cellbound3d"))

    Then
    _ * wsl_runner_host.converge! >> raises(Dev::WslRunnerHost::RestartRequiredError, "wsl --shutdown, then `dev runner register` again")
    error = raises Dev::WslRunnerHost::RestartRequiredError
    error.message.include?("wsl --shutdown")
    harness.events == []
    harness.wirings == []
  end

  test "off WSL (a Mac, a bare Linux box) there is no WSL runner host step: --org without a checkout converges nothing Windows-side" do
    Given "the default harness: the WSL runner host is nil, as WslRunnerHost.for_host answers off WSL"
    harness = build_harness

    When
    harness.command.call(args: parsed_args(harness.command, ["--org", "--ai-flow"]), context: harness.projectless_context)

    Then
    harness.events == [[:converge], [:run], [:after_enroll, "/tmp/runner-dir", 1]]
  end

  test "register's usage carries the three-identity table and the runner-user rule: who mints, who owns, who installs; the login line; examples" do
    Given "the full desc, as `dev runner register --help` prints it"
    desc = usage_command.desc

    Expect "a one-line summary first, then the detail"
    desc.lines.fetch(0).chomp == "Enroll this host as a self-hosted runner in a role, converging its contracts"
    desc.include?("Runner names are <hostname>-<role>[-n]")
    desc.include?("runner_roles:")
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
    desc.include?("dev runner register --org --role agent")
    desc.include?("GITHUB_TOKEN")
  end

  test "--as carries a description, like every register flag" do
    Expect
    usage_command.flags.map(&:name).include?("--as")
  end

  # dev#613: the usage's by-hand commands are the ones to type on *this*
  # host — the runner user as the host resolves it (the prefix's owner
  # after a hand-over), not the rule's default; the default stands in off
  # Linux, where the text describes the Linux rule.
  test "register's usage spells its by-hand commands with the runner user this host resolves — #{what}" do
    Given "a command whose host rule answers #{what}, asked for its usage without --as"
    as_names = []
    command = Dev::Cli::Builtins::RunnerRegisterCommand.new(
      runner_user_factory: ->(name, _ui) {
        as_names << name
        runner_user
      },
      data_root_provisioner: nil, wsl_runner_host: nil,
    )

    When
    desc = command.desc

    Then "every by-hand command carries the name; the rule's default is still named as the rule"
    as_names == [nil]
    desc.include?("sudo -iu #{spelled} gh auth login --with-token")
    desc.include?("`sudo -iu #{spelled} brew ...`")
    desc.include?("by hand, `sudo -iu #{spelled} dev up`")
    desc.include?("(`sudo -u #{spelled}`; no sudoers line")
    desc.include?("`#{spelled}` on Linux")
    desc.include?("(here: #{spelled})")
    desc.include?("the runner user is `runner` by rule (--as renames it)")

    Where
    what                     | runner_user | spelled
    "a host handed to ci"    | ci_identity | "ci"
    "no runner user (a Mac)" | nil         | "runner"
  end

  # --- plumbing ---------------------------------------------------------

  test "the default factories build the real collaborators" do
    Given "a command with its default wiring, every construction boundary intercepted"
    # RunnerSetup#run registers the host, so the test intercepts the
    # construction boundary and asserts the default factories' wiring (the
    # bare ue-engine label is a build host: no job identity to converge).
    # Discovery is redirected at an empty home so the run never
    # depends on this machine's enrollments, and the host rule is answered
    # at its platform seam so the run never converges a user on this one.
    empty_discovery = Dev::RunnerDiscovery.new(home: Dir.mktmpdir)
    context = projectless_context
    # The two gh seams the default wiring reaches before anything converges:
    # the checkout's repo, and the operator pre-flight's probe of its runners.
    registry = typed_mock(Dev::RunnerRegistry)
    setup = typed_mock(Dev::RunnerSetup)
    # The WSL runner host is answered at its platform seam too, so the run never converges Windows-side on a WSL host.
    # No runner user: the jobs' credential is JobGhToken's, stubbed at its seam here (its own default is tested below).

    When "a command with default wiring runs register with --as, the host rule's one input"
    command = Dev::Cli::Builtins::RunnerRegisterCommand.new(data_root_provisioner: nil, wsl_runner_host: nil, job_token_factory: ->(_ui) { no_op_job_token })
    command.call(args: parsed_args(command, ["--labels", "ue-engine", "--as", "ci"]), context: context)

    Then "the expectations on the construction boundary hold"
    1 * Dev::RunnerDiscovery.new >> empty_discovery
    1 * Dev::RunnerUser.for_host(name: "ci", ui: context.ui) >> nil
    1 * Dev::RunnerSetup.current_repo >> "owner/repo"
    1 * Dev::RunnerRegistry.new >> registry
    1 * Dev::RunnerSetup.new(config: Dev::RunnerSetupConfig.new(role: Dev::RunnerRole.build_host(labels: ["ue-engine"])), repo: nil, org: false, as_user: nil, home: nil, path: nil, ui: context.ui) >> setup
    _ * registry.repository >> Dev::RunnerRegistry::Repository.new(id: 1, full_name: "owner/repo", visibility: "private")
    1 * registry.find(scope: "owner/repo", name: "") >> nil
    # The rule's lookup (dev#565): the fresh slot's name, held by nobody.
    1 * registry.find(scope: "owner/repo", name: "box") >> nil
    1 * setup.run
    _ * setup.resolve_dir >> "/tmp/runner-dir"
    _ * setup.resolve_name >> "box"
    _ * setup.resolve_scope >> "owner/repo"
  end

  test "the default pins reader is the checkout's lock and the default reach factory is HostReach over the runner user" do
    Given "a checkout with one gh pin in its lock, a runner user as the host rule, and HostReach intercepted at construction"
    root = Dir.mktmpdir
    File.write(File.join(root, "deps.lock"), "gh:\n  UnrealEngine:\n    group: build\n    version: 5.6.1-css-83\n    repo: satisfactorymodding/UnrealEngine\n")
    empty_discovery = Dev::RunnerDiscovery.new(home: Dir.mktmpdir)
    # Once for the default wiring, once when it widens to the runner user's home.
    runner_user = fake_runner_user(name: "svc-runner", home: Dir.mktmpdir)
    context = build_context(name: "snappy", root: root)
    reach = typed_mock(Dev::HostReach)
    the_lock = Dev::Deps::Lockfile.new(dir: Pathname(root)).read
    registry = typed_mock(Dev::RunnerRegistry)
    setup = typed_mock(Dev::RunnerSetup)

    When "registering in that checkout with default wiring"
    command = Dev::Cli::Builtins::RunnerRegisterCommand.new(data_root_provisioner: nil, wsl_runner_host: nil)
    command.call(args: parsed_args(command, ["--labels", "ue-engine"]), context: context)

    Then "the lock was read from the checkout and checked as the runner user"
    2 * Dev::RunnerDiscovery.new >> empty_discovery
    1 * Dev::RunnerUser.for_host(name: nil, ui: context.ui) >> runner_user
    1 * Dev::HostReach.new(identity: runner_user) >> reach
    1 * Dev::RunnerSetup.current_repo >> "owner/repo"
    1 * Dev::RunnerRegistry.new >> registry
    1 * Dev::RunnerSetup.new(config: Dev::RunnerSetupConfig.new(role: Dev::RunnerRole.build_host(labels: ["ue-engine"])), repo: nil, org: false, as_user: "svc-runner", home: runner_user.home, path: "/opt/brew/bin:/usr/bin", ui: context.ui) >> setup
    the_lock.map(&:name) == ["UnrealEngine"]
    1 * reach.check!(the_lock)
    _ * registry.repository >> Dev::RunnerRegistry::Repository.new(id: 1, full_name: "owner/repo", visibility: "private")
    1 * registry.find(scope: "owner/repo", name: "") >> nil
    1 * registry.find(scope: "owner/repo", name: "box") >> nil
    1 * setup.run
    _ * setup.resolve_dir >> "/tmp/runner-dir"
    _ * setup.resolve_name >> "box"
    _ * setup.resolve_scope >> "owner/repo"
  end

  test "the default repo resolver asks RunnerSetup.current_repo — the one gh seam" do
    Given "a bare register with default wiring, gh answered at RunnerSetup's seam"
    empty_discovery = Dev::RunnerDiscovery.new(home: Dir.mktmpdir)
    registry = typed_mock(Dev::RunnerRegistry)
    setup = typed_mock(Dev::RunnerSetup)
    context = build_context(name: "Cellbound3D")

    When "running bare register inside a checkout whose dev.yml name differs"
    command = Dev::Cli::Builtins::RunnerRegisterCommand.new(runner_user_factory: ->(_name, _ui) { nil }, data_root_provisioner: nil, wsl_runner_host: nil, job_token_factory: ->(_ui) { no_op_job_token })
    command.call(args: no_args, context: context)

    Then "the label came from gh's repo name, lowercased"
    1 * Dev::RunnerDiscovery.new >> empty_discovery
    1 * Dev::RunnerSetup.current_repo >> "d3mlabs/Cellbound-3D"
    1 * Dev::RunnerRegistry.new >> registry
    1 * Dev::RunnerSetup.new(config: Dev::RunnerSetupConfig.new(role: Dev::RunnerRole.build_host(labels: ["cellbound-3d"])), repo: nil, org: false, as_user: nil, home: nil, path: nil, ui: context.ui) >> setup
    _ * registry.repository >> Dev::RunnerRegistry::Repository.new(id: 1, full_name: "d3mlabs/Cellbound-3D", visibility: "private")
    1 * registry.find(scope: "d3mlabs/Cellbound-3D", name: "") >> nil
    1 * registry.find(scope: "d3mlabs/Cellbound-3D", name: "box") >> nil
    1 * setup.run
    _ * setup.resolve_dir >> "/tmp/runner-dir"
    _ * setup.resolve_name >> "box"
    _ * setup.resolve_scope >> "d3mlabs/Cellbound-3D"
  end

  test "the default identity factory is JobIdentity.for_host over the role's user, the runner user and the Ui" do
    Given "a checkout declaring a role with a job identity, register with default wiring, JobIdentity intercepted at its platform seam"
    empty_discovery = Dev::RunnerDiscovery.new(home: Dir.mktmpdir)
    context = build_context(name: "Cellbound3D", runner_roles: { "ue-farm" => FARM })
    # A Mac: no runner user, so the identity is spawned from the operator (nil).
    identity = typed_mock(Dev::JobIdentity)
    # The jobs' credential, the default wiring's other Mac-side construction (JobGhToken).
    token = typed_mock(Dev::JobGhToken)
    registry = typed_mock(Dev::RunnerRegistry)
    setup = typed_mock(Dev::RunnerSetup)
    role = FARM.bind(repo: "owner/repo", version: nil)

    When "registering the declared role in that checkout with default wiring"
    command = Dev::Cli::Builtins::RunnerRegisterCommand.new(data_root_provisioner: nil, wsl_runner_host: nil)
    command.call(args: parsed_args(command, ["--role", "ue-farm"]), context: context)

    Then "the identity for_host built was the one converged and told of the slot"
    1 * Dev::RunnerDiscovery.new >> empty_discovery
    1 * Dev::RunnerUser.for_host(name: nil, ui: context.ui) >> nil
    1 * Dev::RunnerSetup.current_repo >> "owner/repo"
    1 * Dev::JobIdentity.for_host(user: "ue-builder", runner_user: nil, ui: context.ui) >> identity
    1 * Dev::JobGhToken.new(ui: context.ui) >> token
    1 * Dev::RunnerRegistry.new >> registry
    1 * Dev::RunnerSetup.new(config: Dev::RunnerSetupConfig.new(role: role), repo: nil, org: false, as_user: nil, home: nil, path: nil, ui: context.ui) >> setup
    1 * Dev::RunnerSetup.new(config: Dev::RunnerSetupConfig.new(role: role, dir: "/tmp/runner-dir", name: "box-ue-farm", replace: false), repo: nil, org: false, as_user: nil, home: nil, path: nil, ui: context.ui) >> setup
    1 * identity.converge!
    1 * identity.after_enroll!(runner_dir: "/tmp/runner-dir", slot: 1)
    1 * token.ensure!(runner_dir: "/tmp/runner-dir")
    _ * registry.repository >> Dev::RunnerRegistry::Repository.new(id: 1, full_name: "owner/repo", visibility: "private")
    1 * registry.find(scope: "owner/repo", name: "") >> nil
    1 * registry.find(scope: "owner/repo", name: "box-ue-farm") >> nil
    1 * setup.run
    _ * setup.resolve_dir >> "/tmp/runner-dir"
    # The host; a declared role's slot 1 is named apart from it
    # (`<host>-<role>`), so the enrolling setup is a second construction
    # told its name and dir.
    _ * setup.resolve_name >> "box"
    _ * setup.resolve_scope >> "owner/repo"
  end

  private

  Harness = Struct.new(:command, :wirings, :events, :out, :torn_down, :ui, :as_names, :factory_uis, :reach_roots, :identities,
    :hook_removals, :hook_users, :token_ensured, :token_uis, :slot_order, :references, keyword_init: true) do
    # A project context carrying this harness's Ui — the terminal the
    # command asks at — and the runner roles its dev.yml declares.
    def build_context(name:, engine: nil, root: "/tmp/runner-test", runner_roles: {})
      Dev::Cli::ExecutionContext.new(
        ui: ui,
        project: Dev::Cli::ProjectContext.new(name: name, root: Pathname.new(root), engine: engine, runner_roles: runner_roles),
      )
    end

    # The same, with no project (`--org`).
    def projectless_context
      Dev::Cli::ExecutionContext.new(ui: ui)
    end

    # The enrollments run (`config.sh` ceremonies), apart from the job
    # identity's own events — for tests about which slots enroll.
    def enrollments
      events.select { |event| event == [:run] }
    end
  end

  # A command over recording seams: the setup factory records each
  # (config, repo, org) wiring and answers with a setup recording its run;
  # the engine step records its provision in `events`; the identity
  # factory records who it was asked for (user, runner user, Ui) and
  # answers a job identity recording its lifecycle in `events`;
  # discovery reads a real (tmp) home; the registry is the injected fake;
  # the teardown resolves for real over that home but only records what
  # it would remove; the Ui is a RecordingUi over the same `out` (plain
  # tier, so `out.string` reads every line) each test scripts (tests that
  # say nothing tolerate no question).
  def build_harness(home: Dir.mktmpdir, registry: FakeRegistry.new,
                    scope: "d3mlabs/cellbound-3d", repo: "d3mlabs/cellbound-3d",
                    repo_resolver: nil, runner_user: nil, data_root_provisioner: nil, wsl_runner_host: nil, reach: nil,
                    pins: [], hostname: "mac1", refresher: ->(_scope) { raise "no refresh expected" },
                    referenced_role_loader: FakeReferencedRoleLoader.new({}))
    wirings = []
    events = []
    torn_down = []
    as_names = []
    factory_uis = []
    reach_roots = []
    identities = []
    hook_removals = []
    hook_users = []
    token_ensured = []
    token_uis = []
    # The per-slot steps in the order they ran, hook and token interleaved.
    slot_order = []
    out = StringIO.new
    # A setup per dir: the default one for a config naming none, one
    # resolving to the config's dir otherwise (a further slot's, or a
    # re-enrollment's).
    setups = Hash.new do |cache, dir|
      cache[dir] = RecordingSetup.new(dir: dir || "/tmp/runner-dir", hostname: hostname, scope: scope, events: events)
    end
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
      # The role's job identity, asked for only by a role declaring one:
      # who it is, the runner user it is spawned from, the Ui it speaks on.
      identity_factory: ->(user, runner_user_name, ui) {
        identities << [user, runner_user_name, ui]
        recorded_identity(events)
      },
      discovery: discovery,
      registry: registry,
      teardown: teardown,
      engine_provisioner: RecordingEngineProvisioner.new(events: events),
      refresher: refresher,
      # The retired job-started hook's migration (dev#700): which slot dirs
      # it was asked to clean, and the runner user it was built to write as.
      retired_hook_factory: ->(hook_user, _ui) {
        hook_users << hook_user
        RecordingRetiredJobHook.new(removals: hook_removals, slot_order: slot_order)
      },
      # The jobs' gh credential (JobGhToken): built once per run on a Mac,
      # never on the Linux rule; which slot dirs it was asked to ensure.
      job_token_factory: ->(ui) {
        token_uis << ui
        RecordingJobGhToken.new(ensured: token_ensured, slot_order: slot_order)
      },
      # What a referenced role (dev#701) resolves to; the default answers
      # nothing, so a test about a reference says what it reads.
      referenced_role_loader: referenced_role_loader,
    )
    Harness.new(command: command, wirings: wirings, events: events, out: out,
      torn_down: torn_down, ui: ui, as_names: as_names, factory_uis: factory_uis, reach_roots: reach_roots, identities: identities,
      hook_removals: hook_removals, hook_users: hook_users, token_ensured: token_ensured, token_uis: token_uis, slot_order: slot_order,
      references: referenced_role_loader)
  end

  # The referenced-role loader's seam: answers each reference with the
  # role a test canned for it and records what it was asked — the
  # reference and the lock it was handed. gh is never reached.
  class FakeReferencedRoleLoader < Dev::Cli::ReferencedRoleLoader
    attr_reader :loads

    def initialize(answers)
      super(executor: nil)
      @answers = answers
      @loads = []
    end

    def load(reference, pins)
      @loads << [reference, pins]
      @answers.fetch(reference)
    end
  end

  # A setup that records its `run` into the harness's `events` and answers
  # the dir, name and scope it was built for; the ceremony itself never runs.
  class RecordingSetup < Dev::RunnerSetup
    def initialize(dir:, hostname:, scope:, events:)
      @dir = dir
      @hostname = hostname
      @scope = scope
      @events = events
    end

    def run
      @events << [:run]
    end

    def resolve_dir
      @dir
    end

    def resolve_name
      @hostname
    end

    def resolve_scope
      @scope
    end
  end

  # The engine step, recording each provision (the hint's cpus and memory)
  # into the harness's `events`, beside the identity's — for tests about
  # whether and when register brings the engine up.
  class RecordingEngineProvisioner < Dev::EngineProvisioner
    def initialize(events:)
      @events = events
    end

    def provision!(resources:)
      @events << [:engine, resources&.cpus, resources&.memory_gib]
    end
  end

  # The retired hook's migration, recording which slot dirs it was asked
  # to clean and where that fell among the per-slot steps.
  class RecordingRetiredJobHook < Dev::RetiredJobHook
    def initialize(removals:, slot_order:)
      @removals = removals
      @slot_order = slot_order
    end

    def remove!(runner_dir:)
      @removals << runner_dir
      @slot_order << [:hook, runner_dir]
    end
  end

  # The jobs' gh credential, recording which slot dirs it was asked to
  # ensure and where that fell among the per-slot steps; nothing is asked.
  class RecordingJobGhToken < Dev::JobGhToken
    def initialize(ensured: [], slot_order: [])
      @ensured = ensured
      @slot_order = slot_order
    end

    def ensure!(runner_dir:)
      @ensured << runner_dir
      @slot_order << [:token, runner_dir]
    end
  end

  # The runner user as register sees it — a real one, with a name, a home
  # and a path — whose converge and login steps do nothing: a test about
  # either scripts it on the instance.
  class FakeRunnerUser < Dev::RunnerUser
    def initialize(name:, home:)
      super(name: name, home_of: ->(_user) { home }, brew: nil, path: "/opt/brew/bin:/usr/bin", tap: nil, operator: "human")
    end

    def converge!; end

    def ensure_gh_authenticated!; end
  end

  # A job identity recording the lifecycle a register run drives into
  # `events`: the converge, the engine step (only where the served repo
  # pins an image) and each slot's after-enroll. A typed fake: JobIdentity
  # is abstract over the platform steps, which register never reaches.
  #
  # @param events [Array<Array>] the harness's event log
  # @return [Dev::JobIdentity]
  def recorded_identity(events)
    identity = typed_mock(Dev::JobIdentity)
    identity.define_singleton_method(:converge!) { events << [:converge] }
    identity.define_singleton_method(:ensure_engine!) do |cpus: nil, memory_gib: nil, disk_gib: nil|
      events << [:engine_up, cpus, memory_gib, disk_gib]
    end
    identity.define_singleton_method(:after_enroll!) { |runner_dir:, slot:| events << [:after_enroll, runner_dir, slot] }
    identity
  end

  # A checkout whose VERSION reads `version`: what a grouped role binds
  # its pins to (the series, `v<major>`). Returns the project root.
  def declaring_checkout(version:)
    root = Dir.mktmpdir("runner-declaring-checkout")
    File.write(File.join(root, Dev::Lifecycle::ProjectVersion::FILE_NAME), "#{version}\n")
    root
  end

  # The command with its default wiring but the three platform seams
  # answered off (a Mac with no runner user, no data root, no WSL side):
  # usage and flags do not depend on the host, and the host-probe guard
  # refuses the defaults that would read it.
  def usage_command
    Dev::Cli::Builtins::RunnerRegisterCommand.new(
      runner_user_factory: ->(_name, _ui) { nil }, data_root_provisioner: nil, wsl_runner_host: nil,
    )
  end

  # A .runner record the way config.sh writes it (UTF-8 BOM + JSON).
  # `agent_id` is the registration's id (.runner agentId) — what GitHub's
  # `Runner#id` is compared with to tell this family's own registration
  # from a look-alike (dev#565); 0 by default, an id no registry double
  # here hands out, so a test that means "own" says the id. `pool` is the
  # runner group the registration joined (.runner poolName) — what tells a
  # lost enrollment's family; Default unless a test says so.
  def write_runner(home, dir_name, scope:, name:, agent_id: 0, pool: "Default")
    dir = File.join(home, dir_name)
    FileUtils.mkdir_p(dir)
    record = { "agentId" => agent_id, "agentName" => name, "poolName" => pool, "gitHubUrl" => "https://github.com/#{scope}" }
    File.write(File.join(dir, ".runner"), "\uFEFF#{JSON.generate(record)}")
    dir
  end

  # The orchestrator pool as plans#55 enrolled it on the box: `count` slots
  # in `actions-runner-ai-orchestrator[-n]` named `<hostname>[-n]`, their
  # records in the ai-orchestrator pool, each known to GitHub as an online
  # orchestrator. Returns the registry's map.
  def pool_runners(home, count:, hostname:)
    (1..count).to_h do |slot|
      suffix = slot == 1 ? "" : "-#{slot}"
      write_runner(home, "actions-runner-ai-orchestrator#{suffix}", scope: "d3mlabs", name: "#{hostname}#{suffix}", agent_id: slot, pool: "ai-orchestrator")
      [["d3mlabs", "#{hostname}#{suffix}"], Dev::RunnerRegistry::Runner.new(id: slot, custom_labels: ["ai-orchestrator"], status: "online")]
    end
  end

  # A jobs' credential that does nothing: for tests about another seam
  # on a host with no runner user, where the real one would ask.
  def no_op_job_token
    RecordingJobGhToken.new
  end

  def fake_runner_user(name:, home:)
    FakeRunnerUser.new(name: name, home: home)
  end

  # For a command built without a harness: a context whose Ui is never asked.
  def build_context(name:, engine: nil, root: "/tmp/runner-test", runner_roles: {})
    Dev::Cli::ExecutionContext.new(
      ui: RecordingUi.new,
      project: Dev::Cli::ProjectContext.new(name: name, root: Pathname.new(root), engine: engine, runner_roles: runner_roles),
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
