# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_container_config"
require "dev/builtins/runner_status_command"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::RunnerStatusCommandTest < Minitest::Test
  include SorbetHelper

  test "traits: lifecycle section, guarded like any read command, never stamps" do
    Given "the builtin"
    command = Dev::Builtins::RunnerStatusCommand.new

    Expect
    command.category == Dev::Command::Category::Lifecycle
    command.staleness_exempt? == false
    command.stamps? == false
  end

  test "status wires the inspector with the container fact" do
    Given "a status factory recording its wiring"
    seen = []
    status = typed_mock(Dev::RunnerStatus)
    status.expects(:report).once
    command = Dev::Builtins::RunnerStatusCommand.new(
      runner_status_factory: ->(container_required) {
        seen << container_required
        status
      },
    )
    container = Dev::BuildContainerConfig.new(image: "img", registry: "reg")

    When "running status inside a container repo"
    command.call(args: [], context: build_context(build_container: container))

    Then "the container fact reaches the inspector"
    seen == [true]
  end

  test "status works projectless (the machine view needs no checkout)" do
    Given "a status factory"
    status = typed_mock(Dev::RunnerStatus)
    status.expects(:report).once
    command = Dev::Builtins::RunnerStatusCommand.new(runner_status_factory: ->(_container) { status })

    When "running status with no project"
    command.call(args: [], context: Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui)))

    Then
    true
  end

  test "the default factory builds the real inspector" do
    Given "a command with its default wiring, the construction boundary intercepted"
    status = typed_mock(Dev::RunnerStatus)
    status.expects(:report).once
    Dev::RunnerStatus.expects(:new).with(container_required: false).returns(status)
    command = Dev::Builtins::RunnerStatusCommand.new

    When "running status"
    command.call(args: [], context: Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui)))

    Then "the expectation on the construction boundary holds"
    true
  end

  private

  def build_context(build_container: nil)
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(
        name: "Cellbound3D",
        root: Pathname.new("/tmp/runner-status-test"),
        ruby_version: "4.0.1",
        build_container: build_container,
      ),
    )
  end
end
