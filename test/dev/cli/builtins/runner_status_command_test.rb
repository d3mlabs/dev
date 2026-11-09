# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/builtins/runner_status_command"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/environment_image"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Cli::Builtins::RunnerStatusCommandTest < Minitest::Test
  include SorbetHelper

  test "traits: lifecycle section, guarded like any read command, never stamps" do
    Given "the builtin"
    command = Dev::Cli::Builtins::RunnerStatusCommand.new

    Expect
    command.category == Dev::Cli::Command::Category::Environment
    command.staleness_exempt? == false
    command.stamps? == false
  end

  test "status wires the inspector with the container fact and the context's Ui (plans#52)" do
    Given "a status factory recording its wiring"
    seen = []
    status = typed_mock(Dev::RunnerStatus)
    status.expects(:report).once
    command = Dev::Cli::Builtins::RunnerStatusCommand.new(
      runner_status_factory: ->(container_required, project_root, ui) {
        seen << [container_required, project_root, ui]
        status
      },
    )
    root = image_checkout
    ui = typed_mock(Dev::Ui)

    When "running status inside a container repo (its lock pins an image)"
    command.call(args: no_args, context: build_context(root: root, ui: ui))

    Then "the container fact, the checkout and the Ui reach the inspector"
    seen == [[true, Pathname.new(root), ui]]
  end

  test "status works projectless (the machine view needs no checkout)" do
    Given "a status factory"
    status = typed_mock(Dev::RunnerStatus)
    status.expects(:report).once
    command = Dev::Cli::Builtins::RunnerStatusCommand.new(runner_status_factory: ->(_container, _root, _ui) { status })

    When "running status with no project"
    command.call(args: no_args, context: Dev::Cli::ExecutionContext.new(ui: typed_mock(Dev::Ui)))

    Then
    true
  end

  test "the default factory builds the real inspector" do
    Given "a command with its default wiring, the construction boundary intercepted"
    status = typed_mock(Dev::RunnerStatus)
    status.expects(:report).once
    ui = typed_mock(Dev::Ui)
    Dev::RunnerStatus.expects(:new).with(container_required: false, pins: [], repo: nil, ui: ui).returns(status)
    command = Dev::Cli::Builtins::RunnerStatusCommand.new

    When "running status outside a checkout"
    command.call(args: no_args, context: Dev::Cli::ExecutionContext.new(ui: ui))

    Then "the expectation on the construction boundary holds: no lock, no repo"
    true
  end

  test "in a checkout the default factory hands the inspector the checkout's repo — or nil when gh cannot name it" do
    Given "a checkout with an empty lock, gh answering (or not)"
    root = Pathname.new(Dir.mktmpdir)
    status = typed_mock(Dev::RunnerStatus)
    status.expects(:report).once
    Dev::RunnerSetup.expects(:current_repo).then.raises(Dev::RunnerSetup::Error, "could not resolve the repo via gh: offline") if repo.nil?
    Dev::RunnerSetup.expects(:current_repo).returns(repo) unless repo.nil?
    ui = typed_mock(Dev::Ui)
    Dev::RunnerStatus.expects(:new).with(container_required: false, pins: [], repo: repo, ui: ui).returns(status)
    command = Dev::Cli::Builtins::RunnerStatusCommand.new

    When
    command.call(args: no_args, context: build_context(root: root.to_s, ui: ui))

    Then
    true

    Where
    repo
    "d3mlabs/dev"
    nil
  end

  private

  def build_context(root: "/tmp/runner-status-test", ui: typed_mock(Dev::Ui))
    Dev::Cli::ExecutionContext.new(
      ui: ui,
      project: Dev::Cli::ProjectContext.new(name: "Cellbound3D", root: Pathname.new(root)),
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
