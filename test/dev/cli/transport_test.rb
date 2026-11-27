# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_container"
require "dev/container_github_token"
require "dev/deps/dependency"
require "dev/environment_image"
require "dev/lifecycle"
require "dev/project_container"
require "dev/cli/transport"
require "pathname"
require "stringio"
require "support/fake_container_engine"
require "support/fake_gh"

# The workspace contract each transport keeps: `with_workspace(tree)`
# delivers the tree to the host for the block's duration — through the
# sync step built over that tree for the Actions runner, whose host
# fetches a snapshot; as the checkout itself for the local container,
# which mounts it — and `assert_ready!` refuses, before anything leaves
# the machine, what the transport cannot carry. Dispatch::Remote over the
# whole shape, with a real origin, is DispatchTest.
transform!(RSpock::AST::Transformation)
class Dev::Cli::TransportTest < Minitest::Test
  include SorbetHelper

  SHA = "0123456789abcdef0123456789abcdef01234567"

  # A sync step that yields one given snapshot and touches no git,
  # recording the tree it was built over and the label it synced for.
  class YieldingSync < Dev::Lifecycle::SnapshotSync
    attr_reader :synced

    def initialize(snapshot)
      super(root: Pathname("/nonexistent"))
      @snapshot = snapshot
      @synced = []
    end

    def sync(runner:)
      @synced << runner
      yield @snapshot
    end
  end

  test "inside an Actions job the Actions runner refuses before anything leaves: DispatchFromJobError naming the runner and the rule" do
    Given "a transport built inside a job, over a forge and a workflow that would otherwise be reached"
    gh = FakeGh.new(root: Pathname("/nonexistent"))
    transport = actions_runner(gh, inside_job: true)

    When
    transport.assert_ready!

    Then
    error = raises(Dev::Cli::Transport::ActionsRunner::DispatchFromJobError)
    error.message.include?("would leave this Actions job for runner `ue-engine-hosted`")
    error.message.include?("a job never dispatches a job")
    error.message.include?("provision it from the image, or name a runner that is")
    gh.calls.empty?
  end

  test "ActionsRunner#with_workspace builds the sync step over the tree it is handed, syncs for its label, and yields the pushed snapshot as the workspace" do
    Given
    snapshot = pushed_snapshot(runner: "ue-engine-hosted")
    sync = YieldingSync.new(snapshot)
    built_over = []
    transport = actions_runner(FakeGh.new(root: Pathname("/nonexistent")), sync_for: ->(root) { sync.tap { built_over << root } })
    tree = Pathname("/src/checkout")

    When
    result = transport.with_workspace(tree) { |workspace| [workspace, :ran] }

    Then "the block's value comes back; the workspace is the snapshot, named by its short sha"
    result == [Dev::Lifecycle::Workspace::Snapshot.new(snapshot), :ran]
    result.fetch(0).description == "snapshot 0123456789ab"
    built_over == [tree]
    sync.synced == ["ue-engine-hosted"]
  end

  test "LocalContainer#with_workspace yields the tree itself as the mounted workspace: nothing synced, no git, no forge" do
    Given
    transport = local_container
    tree = Pathname("/src/checkout")

    When
    result = transport.with_workspace(tree) { |workspace| [workspace, :ran] }

    Then "the block's value comes back; the workspace is the checkout, named as the mount it is"
    result == [Dev::Lifecycle::Workspace::Mounted.new(tree), :ran]
    result.fetch(0).description == "the checkout, mounted"
    transport.runner == "container"
  end

  test "the Actions runner refuses a mounted workspace: another transport's delivery, with no branch to dispatch on, and the forge is never asked" do
    Given
    gh = FakeGh.new(root: Pathname("/nonexistent"))
    transport = actions_runner(gh)

    When
    transport.run(Dev::Lifecycle::VerbInvocation.new(words: ["build", "x"]), workspace: Dev::Lifecycle::Workspace::Mounted.new(Pathname("/src/checkout")))

    Then
    error = raises(Dev::Cli::Transport::ActionsRunner::WorkspaceNotSnapshotError)
    error.message.include?("the checkout, mounted")
    error.message.include?("the container's delivery")
    gh.calls.empty?
  end

  test "the default sync step is the lifecycle's, built over the tree it is asked for" do
    Given "a tree, and the lifecycle's sync constructor watched"
    root = Pathname("/proj")
    sync = typed_mock(Dev::Lifecycle::SnapshotSync)

    When
    built = Dev::Cli::Transport::DEFAULT_SYNC_FOR.call(root)

    Then
    1 * Dev::Lifecycle::SnapshotSync.new(root: root) >> sync
    built.equal?(sync)
  end

  private

  def pushed_snapshot(runner:)
    Dev::Lifecycle::Snapshot.new(sha: SHA, branch: Dev::Lifecycle::SnapshotBranch.mint(runner:))
  end

  def actions_runner(gh, sync_for: Dev::Cli::Transport::DEFAULT_SYNC_FOR, inside_job: false)
    Dev::Cli::Transport::ActionsRunner.new(
      runner: "ue-engine-hosted",
      runs: Dev::Lifecycle::WorkflowRuns.new(gh:, sleeper: ->(_seconds) { nil }),
      workflow: Dev::Lifecycle::LifecycleWorkflow.new(root: Pathname("/nonexistent")),
      sync_for:,
      inside_job:,
      out: StringIO.new,
    )
  end

  def local_container
    containers = Dev::ProjectContainer.new(
      project_root: Pathname("/src/checkout"),
      client: Dev::BuildContainer.new(engine: FakeContainerEngine.new),
      github_token: Dev::ContainerGithubToken.new(source: -> { nil }),
    )
    Dev::Cli::Transport::LocalContainer.new(image:, containers:, out: StringIO.new)
  end

  def image
    Dev::EnvironmentImage.from_pin(
      Dev::Deps::Dependency.new(
        name: "cellbound-3d-linux", integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}",
        metadata: {
          "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platform" => "linux/amd64", "platforms" => ["linux/amd64"],
          "registry" => "ghcr.io/d3mlabs", "apt" => [],
        },
      ),
    )
  end
end
