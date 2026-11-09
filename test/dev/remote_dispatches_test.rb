# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/ui"
require "dev/build_container"
require "dev/dispatch"
require "dev/environment_image"
require "dev/lifecycle"
require "dev/project_container"
require "dev/remote_dispatches"
require "dev/transport"
require "pathname"
require "stringio"
require "support/fake_container_engine"
require "support/fake_gh"

transform!(RSpock::AST::Transformation)
class Dev::RemoteDispatchesTest < Minitest::Test
  include SorbetHelper

  test "actions_runner wires a Remote dispatch whose transport carries the label, over the one sync step and forge client" do
    Given
    root = Pathname("/nonexistent/checkout")
    remotes = Dev::RemoteDispatches.new(
      root:, ui: typed_mock(Dev::Ui), out: StringIO.new, runs: Dev::Lifecycle::WorkflowRuns.new(gh: FakeGh.new(root:)),
    )

    When
    dispatch = remotes.actions_runner("ue-engine-hosted")

    Then
    dispatch.is_a?(Dev::Dispatch::Remote)
    dispatch.transport.is_a?(Dev::Transport::ActionsRunner)
    dispatch.transport.runner == "ue-engine-hosted"
    remotes.actions_runner("other").transport.runner == "other"
  end

  test "local_container wires a Remote dispatch whose transport is the project's container of the image, over the same sync step" do
    Given
    root = Pathname("/nonexistent/checkout")
    containers = Dev::ProjectContainer.new(project_root: root, client: Dev::BuildContainer.new(engine: FakeContainerEngine.new))
    remotes = Dev::RemoteDispatches.new(root:, ui: typed_mock(Dev::Ui), out: StringIO.new, containers:)
    image = Dev::EnvironmentImage.new(
      name: "snappy-linux", from: "ghcr.io/d3mlabs/unreal-engine-build-base", from_digest: "a" * 64,
      platform: "linux/amd64", apt: [], registry: "ghcr.io/d3mlabs",
    )

    When
    dispatch = remotes.local_container(image)

    Then
    dispatch.is_a?(Dev::Dispatch::Remote)
    dispatch.transport.is_a?(Dev::Transport::LocalContainer)
    dispatch.transport.runner == "container"
    dispatch.transport.destination == "in snappy-linux (container)"
  end

  test "the defaults build the sync step, the forge client and the workflow over the project root" do
    Given
    root = Pathname("/nonexistent/checkout")

    dispatch = Dev::RemoteDispatches.new(root:, ui: typed_mock(Dev::Ui)).actions_runner("box")

    When "dispatching from a root without the workflow"
    dispatch.dispatch(Dev::Lifecycle::VerbInvocation.new(words: ["build", "x"])) { flunk("the env was resolved") }

    Then "it refuses before any gh or git runs"
    raises Dev::Lifecycle::LifecycleWorkflow::WorkflowMissingError
  end
end
