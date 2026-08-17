# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/runner_setup_command"
require "dev/runner_setup_config"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::RunnerSetupCommandTest < Minitest::Test
  include SorbetHelper

  test "call registers with the dev.yml runner block, repo-scoped by default" do
    Given "a runner-setup command over a recording factory"
    wirings, command = build_recording_command
    context = build_context(runner_config)

    When "running runner-setup with no flags"
    command.call(args: [], context: context)

    Then "the block passes through untouched; repo resolution stays with gh"
    config, repo, org = wirings.fetch(0)
    config == runner_config
    repo.nil?
    org == false
  end

  test "call applies --labels/--dir/--name overrides onto the block" do
    Given "a runner-setup command over a recording factory"
    wirings, command = build_recording_command
    context = build_context(runner_config)

    When "running with identity overrides"
    command.call(
      args: ["--labels", "macos,ue-editor", "--dir", "~/actions-runner-mac", "--name", "mac-box"],
      context: context,
    )

    Then "the overrides replace the block's identity, version rides along"
    config, = wirings.fetch(0)
    config == Dev::RunnerSetupConfig.new(
      labels: "macos,ue-editor", dir: "~/actions-runner-mac", name: "mac-box", version: "2.335.1",
    )
  end

  test "call passes --repo and --org through to the setup" do
    Given "a runner-setup command over a recording factory"
    wirings, command = build_recording_command
    context = build_context(runner_config)

    When "running org-wide for an explicit repo"
    command.call(args: ["--repo", "d3mlabs/dev", "--org"], context: context)

    Then "the scope flags reach the setup"
    _, repo, org = wirings.fetch(0)
    repo == "d3mlabs/dev"
    org == true
  end

  test "the default factory builds the real setup wired to the resolved scope" do
    Given "a command with its default collaborators"
    # RunnerSetup#run registers the host with GitHub, so the test intercepts
    # the construction boundary and asserts the default factory's wiring.
    setup = typed_mock(Dev::RunnerSetup)
    setup.expects(:run).once
    Dev::RunnerSetup.expects(:new).with(config: runner_config, repo: nil, org: false).returns(setup)
    command = Dev::Builtins::RunnerSetupCommand.new

    When "running runner-setup with no flags"
    command.call(args: [], context: build_context(runner_config))

    Then "the expectations on the construction boundary hold"
    true
  end

  test "call without a runner block raises the usage error" do
    Given "a context whose dev.yml has no runner block"
    _, command = build_recording_command
    context = build_context(nil)

    When "running runner-setup"
    command.call(args: [], context: context)

    Then
    raises ArgumentError
  end

  private

  def runner_config
    Dev::RunnerSetupConfig.new(labels: "ue-engine", dir: "~/actions-runner-ue", name: "gaming-box", version: "2.335.1")
  end

  # A command whose factory records each (config, repo, org) wiring and
  # returns a no-op setup.
  def build_recording_command
    wirings = []
    setup = typed_mock(Dev::RunnerSetup)
    setup.stubs(:run)
    command = Dev::Builtins::RunnerSetupCommand.new(
      runner_setup_factory: ->(config, repo, org) {
        wirings << [config, repo, org]
        setup
      },
    )
    [wirings, command]
  end

  def build_context(runner)
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      ruby_version: "4.0.1",
      project_root: Pathname.new("/tmp/runner-setup-test"),
      runner: runner,
    )
  end
end
