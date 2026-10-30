# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/runner_status_command"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/environment_image"
require "pathname"
require "tmpdir"

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
      runner_status_factory: ->(container_required, project_root) {
        seen << [container_required, project_root]
        status
      },
    )
    root = image_checkout

    When "running status inside a container repo (its lock pins an image)"
    command.call(args: no_args, context: build_context(root: root))

    Then "the container fact and the checkout reach the inspector"
    seen == [[true, Pathname.new(root)]]
  end

  test "status works projectless (the machine view needs no checkout)" do
    Given "a status factory"
    status = typed_mock(Dev::RunnerStatus)
    status.expects(:report).once
    command = Dev::Builtins::RunnerStatusCommand.new(runner_status_factory: ->(_container, _root) { status })

    When "running status with no project"
    command.call(args: no_args, context: Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui)))

    Then
    true
  end

  test "the default factory builds the real inspector" do
    Given "a command with its default wiring, the construction boundary intercepted"
    status = typed_mock(Dev::RunnerStatus)
    status.expects(:report).once
    Dev::RunnerStatus.expects(:new).with(container_required: false, pins: []).returns(status)
    command = Dev::Builtins::RunnerStatusCommand.new

    When "running status"
    command.call(args: no_args, context: Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui)))

    Then "the expectation on the construction boundary holds"
    true
  end

  private

  def build_context(root: "/tmp/runner-status-test")
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(name: "Cellbound3D", root: Pathname.new(root)),
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
end
