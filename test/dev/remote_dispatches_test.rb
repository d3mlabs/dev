# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/ui"
require "dev/dispatch"
require "dev/lifecycle"
require "dev/remote_dispatches"
require "dev/transport"
require "pathname"
require "stringio"
require "support/fake_gh"

transform!(RSpock::AST::Transformation)
class Dev::RemoteDispatchesTest < Minitest::Test
  include SorbetHelper

  test "actions_runner wires a Remote dispatch whose transport carries the label, over the one sync step and forge client" do
    Given
    root = Pathname("/nonexistent/checkout")
    remotes = Dev::RemoteDispatches.new(
      root:, ui: typed_mock(Dev::Cli::Ui), out: StringIO.new, runs: Dev::Lifecycle::WorkflowRuns.new(gh: FakeGh.new(root:)),
    )

    When
    dispatch = remotes.actions_runner("ue-engine-hosted")

    Then
    dispatch.is_a?(Dev::Dispatch::Remote)
    dispatch.transport.is_a?(Dev::Transport::ActionsRunner)
    dispatch.transport.runner == "ue-engine-hosted"
    remotes.actions_runner("other").transport.runner == "other"
  end

  test "the defaults build the sync step, the forge client and the workflow over the project root" do
    Given
    root = Pathname("/nonexistent/checkout")

    dispatch = Dev::RemoteDispatches.new(root:, ui: typed_mock(Dev::Cli::Ui)).actions_runner("box")

    When "dispatching from a root without the workflow"
    dispatch.dispatch(Dev::Lifecycle::VerbInvocation.new(words: ["build", "x"])) { flunk("the env was resolved") }

    Then "it refuses before any gh or git runs"
    raises Dev::Lifecycle::LifecycleWorkflow::WorkflowMissingError
  end
end
