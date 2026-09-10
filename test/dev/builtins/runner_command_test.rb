# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/runner_command"
require "dev/runner_setup_config"
require "pathname"

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

transform!(RSpock::AST::Transformation)
class Dev::Builtins::RunnerCommandTest < Minitest::Test
  include SorbetHelper

  test "register enrolls with the dev.yml runner block, repo-scoped by default" do
    Given "a runner command over a recording factory"
    wirings, _events, command = build_recording_command
    context = build_context(runner_config)

    When "running register with no flags"
    command.call(args: ["register"], context: context)

    Then "the block passes through untouched; repo resolution stays with gh"
    config, repo, org = wirings.fetch(0)
    config == runner_config
    repo.nil?
    org == false
  end

  test "register applies --labels/--dir/--name overrides onto the block" do
    Given "a runner command over a recording factory"
    wirings, _events, command = build_recording_command
    context = build_context(runner_config)

    When "running with identity overrides"
    command.call(
      args: ["register", "--labels", "macos,ue-editor", "--dir", "~/actions-runner-mac", "--name", "mac-box"],
      context: context,
    )

    Then "the overrides replace the block's identity, version rides along"
    config, = wirings.fetch(0)
    config == Dev::RunnerSetupConfig.new(
      labels: "macos,ue-editor", dir: "~/actions-runner-mac", name: "mac-box", version: "2.335.1",
    )
  end

  test "register passes --repo and --org through to the setup" do
    Given "a runner command over a recording factory"
    wirings, _events, command = build_recording_command
    context = build_context(runner_config)

    When "running org-wide for an explicit repo"
    command.call(args: ["register", "--repo", "d3mlabs/dev", "--org"], context: context)

    Then "the scope flags reach the setup"
    _, repo, org = wirings.fetch(0)
    repo == "d3mlabs/dev"
    org == true
  end

  test "register converges contracts before the ceremony and finishes the posture after it" do
    Given "an agent-labeled block over a recording contract"
    _wirings, events, command = build_recording_command(contracts: 1)
    context = build_context(runner_config)

    When "registering"
    command.call(args: ["register"], context: context)

    Then "converge -> enroll -> after_enroll, with the enrolled dir"
    events == [
      [:converge, false, nil, nil],
      [:run],
      [:after_enroll, "/tmp/runner-dir"],
    ]
  end

  test "register hands the contract the container fact and sizing hint" do
    Given "a container repo with a resources block"
    _wirings, events, command = build_recording_command(contracts: 1)
    container = Dev::BuildContainerConfig.new(
      image: "img", registry: "reg",
      resources: Dev::BuildContainerConfig::Resources.new(cpus: 8, memory_gib: 24),
    )
    context = build_context(runner_config, build_container: container)

    When "registering"
    command.call(args: ["register"], context: context)

    Then
    events.fetch(0) == [:converge, true, 8, 24]
  end

  test "the runner-setup alias implies register" do
    Given "the alias wiring (implied subcommand)"
    wirings, _events, command = build_recording_command(implied_subcommand: "register")
    context = build_context(runner_config)

    When "running with bare flags, no subcommand"
    command.call(args: ["--org"], context: context)

    Then
    wirings.fetch(0).fetch(2) == true
  end

  test "an unknown subcommand raises the usage error" do
    Given "a runner command"
    _wirings, _events, command = build_recording_command
    context = build_context(runner_config)

    When "running an unknown subcommand"
    command.call(args: ["bogus"], context: context)

    Then
    raises ArgumentError
  end

  test "register without a runner block raises the usage error" do
    Given "a context whose dev.yml has no runner block"
    _wirings, _events, command = build_recording_command
    context = build_context(nil)

    When "registering"
    command.call(args: ["register"], context: context)

    Then
    raises ArgumentError
  end

  test "the --agent-user flag reaches the contracts factory" do
    Given "a factory recording its agent_user argument"
    seen = []
    setup = typed_mock(Dev::RunnerSetup)
    setup.stubs(:run)
    setup.stubs(:resolve_dir).returns("/tmp/runner-dir")
    command = Dev::Builtins::RunnerCommand.new(
      runner_setup_factory: ->(_c, _r, _o) { setup },
      contracts_factory: ->(labels, agent_user) {
        seen << [labels, agent_user]
        []
      },
    )

    When "registering with the override"
    command.call(args: ["register", "--agent-user", "ci"], context: build_context(runner_config))

    Then
    seen == [["ue-engine", "ci"]]
  end

  private

  def runner_config
    Dev::RunnerSetupConfig.new(labels: "ue-engine", dir: "~/actions-runner-ue", name: "gaming-box", version: "2.335.1")
  end

  # A command whose setup factory records each (config, repo, org) wiring
  # and whose contracts record their lifecycle into a shared event log the
  # no-op setup also appends to.
  def build_recording_command(contracts: 0, implied_subcommand: nil)
    wirings = []
    events = []
    setup = typed_mock(Dev::RunnerSetup)
    setup.stubs(:run).with { events << [:run] || true }
    setup.stubs(:resolve_dir).returns("/tmp/runner-dir")
    command = Dev::Builtins::RunnerCommand.new(
      runner_setup_factory: ->(config, repo, org) {
        wirings << [config, repo, org]
        setup
      },
      contracts_factory: ->(_labels, _agent_user) {
        Array.new(contracts) { RecordedContract.new(events) }
      },
      implied_subcommand: implied_subcommand,
    )
    [wirings, events, command]
  end

  def build_context(runner, build_container: nil)
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(
        root: Pathname.new("/tmp/runner-test"),
        ruby_version: "4.0.1",
        runner: runner,
        build_container: build_container,
      ),
    )
  end
end
