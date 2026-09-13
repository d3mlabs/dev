# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/runner_command"
require "dev/label_contracts"
require "dev/runner_discovery"
require "dev/runner_registry"
require "dev/runner_setup_config"
require "fileutils"
require "json"
require "pathname"
require "stringio"
require "tmpdir"

# Records the contract lifecycle a register run drives.
class RecordedContract
  attr_reader :events

  def initialize(events)
    @events = events
  end

  def converge!(container:, cpus: nil, memory_gib: nil)
    @events << [:converge, container, cpus, memory_gib]
  end

  def after_enroll!(runner_dir:)
    @events << [:after_enroll, runner_dir]
  end
end unless defined?(RecordedContract)

# The GitHub-side registry seam: answers find from a canned map and
# records amends.
class FakeRegistry
  attr_reader :amends

  def initialize(runners: {})
    @runners = runners
    @amends = []
  end

  def find(scope:, name:)
    @runners[[scope, name]]
  end

  def amend!(scope:, runner_id:, labels:)
    @amends << [scope, runner_id, labels]
  end
end unless defined?(FakeRegistry)

transform!(RSpock::AST::Transformation)
class Dev::Builtins::RunnerCommandTest < Minitest::Test
  include SorbetHelper

  # --- label + scope resolution ---------------------------------------

  test "bare register derives the repo label from the project name" do
    Given "a checkout of a project named Cellbound3D"
    harness = build_harness
    context = build_context(name: "Cellbound3D")

    When "running register with no flags"
    harness.command.call(args: ["register"], context: context)

    Then "the label is the project slug, repo-scoped, dir/name defaulted"
    config, repo, org = harness.wirings.fetch(0)
    config == Dev::RunnerSetupConfig.new(labels: "cellbound3d")
    repo.nil?
    org == false
  end

  test "--org --ai-flow enrolls the full ai-flow label vocabulary" do
    Given "a harness"
    harness = build_harness

    When "registering the org agent host"
    harness.command.call(args: ["register", "--org", "--ai-flow"], context: projectless_context)

    Then "the labels are dev's documented mirror of ai-flow's vocabulary"
    config, _repo, org = harness.wirings.fetch(0)
    config.labels == Dev::LabelContracts::AI_FLOW_LABELS.join(",")
    org == true
  end

  test "--labels overrides any derivation" do
    Given "a checkout whose derived label would differ"
    harness = build_harness
    context = build_context(name: "UnrealEngine")

    When "registering with an explicit custom set"
    harness.command.call(args: ["register", "--labels", "macos,ue-editor"], context: context)

    Then
    harness.wirings.fetch(0).fetch(0).labels == "macos,ue-editor"
  end

  test "--ai-flow with --labels is a contradiction and raises" do
    Given "a harness"
    harness = build_harness

    When "passing both"
    harness.command.call(args: ["register", "--org", "--ai-flow", "--labels", "ai-ask"], context: projectless_context)

    Then
    raises ArgumentError
  end

  test "--org without a role raises: an org runner's labels are not derivable" do
    Given "a harness"
    harness = build_harness

    When "registering org-scoped with no label source"
    harness.command.call(args: ["register", "--org"], context: build_context(name: "Cellbound3D"))

    Then
    raises ArgumentError
  end

  test "bare register outside a project raises: nothing to derive from" do
    Given "a harness"
    harness = build_harness

    When "registering with no checkout and no labels"
    harness.command.call(args: ["register"], context: projectless_context)

    Then
    raises ArgumentError
  end

  test "register applies --dir/--name/--repo/--org flags" do
    Given "a harness"
    harness = build_harness

    When "running with identity overrides"
    harness.command.call(
      args: ["register", "--labels", "ue-engine", "--dir", "~/actions-runner-ue",
             "--name", "gaming-box", "--repo", "d3mlabs/unreal-engine", "--org"],
      context: projectless_context,
    )

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
    context = build_context(name: "Cellbound3D")

    When "registering"
    harness.command.call(args: ["register"], context: context)

    Then "the ceremony runs end to end with the enrolled dir"
    harness.events == [
      [:converge, false, nil, nil],
      [:run],
      [:after_enroll, "/tmp/runner-dir"],
    ]
  end

  test "an enrolled scope with drifted labels is amended in place, never re-enrolled" do
    Given "this host already serves the org, with a stale label set, in a repo-named dir"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs", name: "mac-box")
    registry = FakeRegistry.new(
      runners: { ["d3mlabs", "mac-box"] => Dev::RunnerRegistry::Runner.new(id: 42, custom_labels: ["cellbound3d"]) },
    )
    harness = build_harness(contracts: 1, home: home, registry: registry, scope: "d3mlabs")

    When "registering the agent host"
    harness.command.call(args: ["register", "--org", "--ai-flow"], context: projectless_context)

    Then "one label amend; the service and dir stay put; contracts still converge"
    registry.amends == [["d3mlabs", 42, Dev::LabelContracts::AI_FLOW_LABELS]]
    harness.events == [
      [:converge, false, nil, nil],
      [:after_enroll, dir],
    ]
  end

  test "an enrolled scope with current labels is a no-op amend" do
    Given "the enrollment already advertises the desired set"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs/cellbound-3d", name: "box")
    registry = FakeRegistry.new(
      runners: { ["d3mlabs/cellbound-3d", "box"] => Dev::RunnerRegistry::Runner.new(id: 7, custom_labels: ["cellbound3d"]) },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs/cellbound-3d")

    When "re-running register"
    harness.command.call(args: ["register"], context: build_context(name: "Cellbound3D"))

    Then "nothing is amended and nothing re-enrolls"
    registry.amends == []
    harness.events == []
    harness.out.string.include?("nothing to amend")
  end

  test "a local enrollment GitHub has lost re-enrolls into the same dir" do
    Given "a .runner record whose runner is gone server-side"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs", name: "mac-box")
    harness = build_harness(home: home, registry: FakeRegistry.new, scope: "d3mlabs")

    When "registering"
    harness.command.call(args: ["register", "--org", "--labels", "ai-build"], context: projectless_context)

    Then "the re-enrollment reuses the discovered dir, not a label-derived one"
    harness.events == [[:run]]
    harness.wirings.fetch(1).fetch(0).dir == dir
  end

  test "--dir skips discovery: the dir is the operator's to pick" do
    Given "an enrollment discovery would have found"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs", name: "mac-box")
    registry = FakeRegistry.new(
      runners: { ["d3mlabs", "mac-box"] => Dev::RunnerRegistry::Runner.new(id: 42, custom_labels: ["x"]) },
    )
    harness = build_harness(home: home, registry: registry, scope: "d3mlabs")

    When "registering with an explicit dir"
    harness.command.call(
      args: ["register", "--org", "--labels", "ai-build", "--dir", "~/actions-runner-heavy"],
      context: projectless_context,
    )

    Then "the full enrollment runs there; no amend"
    harness.events == [[:run]]
    registry.amends == []
  end

  # --- contracts --------------------------------------------------------

  test "register hands the contract the container fact and sizing hint" do
    Given "a container repo with a resources block"
    harness = build_harness(contracts: 1)
    container = Dev::BuildContainerConfig.new(
      image: "img", registry: "reg",
      resources: Dev::BuildContainerConfig::Resources.new(cpus: 8, memory_gib: 24),
    )
    context = build_context(name: "Cellbound3D", build_container: container)

    When "registering"
    harness.command.call(args: ["register"], context: context)

    Then
    harness.events.fetch(0) == [:converge, true, 8, 24]
  end

  test "the --agent-user flag reaches the contracts factory" do
    Given "a factory recording its agent_user argument"
    seen = []
    recorder = ->(labels, agent_user) {
      seen << [labels, agent_user]
      []
    }
    harness = build_harness(contracts_factory: recorder)

    When "registering with the override"
    harness.command.call(
      args: ["register", "--org", "--ai-flow", "--agent-user", "ci"],
      context: projectless_context,
    )

    Then
    seen == [[Dev::LabelContracts::AI_FLOW_LABELS.join(","), "ci"]]
  end

  # --- plumbing ---------------------------------------------------------

  test "the runner-setup alias implies register" do
    Given "the alias wiring (implied subcommand)"
    harness = build_harness(implied_subcommand: "register")

    When "running with bare flags, no subcommand"
    harness.command.call(args: ["--org", "--ai-flow"], context: projectless_context)

    Then
    harness.wirings.fetch(0).fetch(2) == true
  end

  test "status wires the inspector with the container fact" do
    Given "a status factory recording its wiring"
    seen = []
    status = typed_mock(Dev::RunnerStatus)
    status.expects(:report).once
    command = Dev::Builtins::RunnerCommand.new(
      runner_status_factory: ->(container_required) {
        seen << container_required
        status
      },
    )
    container = Dev::BuildContainerConfig.new(image: "img", registry: "reg")

    When "running status inside a container repo and outside any project"
    command.call(args: ["status"], context: build_context(name: "Cellbound3D", build_container: container))

    Then "the container fact reaches the inspector"
    seen == [true]
  end

  test "status works projectless (the machine view needs no checkout)" do
    Given "a status factory"
    status = typed_mock(Dev::RunnerStatus)
    status.expects(:report).once
    command = Dev::Builtins::RunnerCommand.new(runner_status_factory: ->(_container) { status })

    When "running status with no project"
    command.call(args: ["status"], context: projectless_context)

    Then
    true
  end

  test "the default factories build the real collaborators" do
    Given "a command with its default wiring, every construction boundary intercepted"
    # RunnerSetup#run registers the host and RunnerStatus#report inspects it,
    # so the test intercepts both construction boundaries and asserts the
    # default factories' wiring (the bare ue-engine label makes the default
    # contracts factory resolve to no contracts). Discovery is redirected at
    # an empty home so the run never depends on this machine's enrollments.
    empty_discovery = Dev::RunnerDiscovery.new(home: Dir.mktmpdir)
    Dev::RunnerDiscovery.expects(:new).returns(empty_discovery)
    setup = typed_mock(Dev::RunnerSetup)
    setup.expects(:run).once
    setup.stubs(:resolve_dir).returns("/tmp/runner-dir")
    setup.stubs(:resolve_scope).returns("owner/repo")
    Dev::RunnerSetup.expects(:new)
      .with(config: Dev::RunnerSetupConfig.new(labels: "ue-engine"), repo: nil, org: false).returns(setup)
    status = typed_mock(Dev::RunnerStatus)
    status.expects(:report).once
    Dev::RunnerStatus.expects(:new).with(container_required: false).returns(status)
    command = Dev::Builtins::RunnerCommand.new

    When "running register, then status"
    command.call(args: ["register", "--labels", "ue-engine"], context: projectless_context)
    command.call(args: ["status"], context: projectless_context)

    Then "the expectations on the construction boundaries hold"
    true
  end

  test "an unknown subcommand raises the usage error" do
    Given "a harness"
    harness = build_harness

    When "running an unknown subcommand"
    harness.command.call(args: ["bogus"], context: projectless_context)

    Then
    raises ArgumentError
  end

  private

  Harness = Struct.new(:command, :wirings, :events, :out, keyword_init: true)

  # A command over recording seams: the setup factory records each
  # (config, repo, org) wiring and answers with a no-op setup; contracts
  # record their lifecycle; discovery reads a real (tmp) home; the registry
  # is the injected fake.
  def build_harness(contracts: 0, home: Dir.mktmpdir, registry: FakeRegistry.new,
                    scope: "d3mlabs/cellbound-3d", implied_subcommand: nil, contracts_factory: nil)
    wirings = []
    events = []
    out = StringIO.new
    setup = typed_mock(Dev::RunnerSetup)
    setup.stubs(:run).with { events << [:run] || true }
    setup.stubs(:resolve_dir).returns("/tmp/runner-dir")
    setup.stubs(:resolve_scope).returns(scope)
    command = Dev::Builtins::RunnerCommand.new(
      runner_setup_factory: ->(config, repo, org) {
        wirings << [config, repo, org]
        setup
      },
      contracts_factory: contracts_factory || ->(_labels, _agent_user) {
        Array.new(contracts) { RecordedContract.new(events) }
      },
      discovery: Dev::RunnerDiscovery.new(home: home),
      registry: registry,
      out: out,
      implied_subcommand: implied_subcommand,
    )
    Harness.new(command: command, wirings: wirings, events: events, out: out)
  end

  # A .runner record the way config.sh writes it (UTF-8 BOM + JSON).
  def write_runner(home, dir_name, scope:, name:)
    dir = File.join(home, dir_name)
    FileUtils.mkdir_p(dir)
    record = { "agentName" => name, "gitHubUrl" => "https://github.com/#{scope}" }
    File.write(File.join(dir, ".runner"), "\uFEFF#{JSON.generate(record)}")
    dir
  end

  def build_context(name:, build_container: nil)
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(
        name: name,
        root: Pathname.new("/tmp/runner-test"),
        ruby_version: "4.0.1",
        build_container: build_container,
      ),
    )
  end

  def projectless_context
    Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui))
  end
end
