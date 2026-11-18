# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle/snapshot"
require "dev/lifecycle/snapshot_branch"
require "dev/lifecycle/workspace"
require "pathname"

# What a build host holds of the tree: the snapshot the sync step pushed
# (a runner's), named on the crossing line by its short sha, or the
# checkout itself bind-mounted (the container's).
transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::WorkspaceTest < Minitest::Test
  SHA = "0123456789abcdef0123456789abcdef01234567"

  test "a snapshot workspace carries the snapshot and names itself by the short sha" do
    Given
    snapshot = Dev::Lifecycle::Snapshot.new(sha: SHA, branch: Dev::Lifecycle::SnapshotBranch.mint(runner: "box"))

    When
    workspace = Dev::Lifecycle::Workspace::Snapshot.new(snapshot)

    Then
    workspace.is_a?(Dev::Lifecycle::Workspace)
    workspace.snapshot.equal?(snapshot)
    workspace.description == "snapshot 0123456789ab"
  end

  test "snapshot workspaces compare by their snapshot" do
    Given
    branch = Dev::Lifecycle::SnapshotBranch.mint(runner: "box")
    snapshot = Dev::Lifecycle::Snapshot.new(sha: SHA, branch:)
    other = Dev::Lifecycle::Snapshot.new(sha: "f" * 40, branch:)

    Expect
    assert_value_semantics Dev::Lifecycle::Workspace::Snapshot.new(snapshot),
      equal_to: Dev::Lifecycle::Workspace::Snapshot.new(snapshot),
      unequal_to: [Dev::Lifecycle::Workspace::Snapshot.new(other), snapshot]
  end

  test "a mounted workspace carries the checkout's path and names itself as the mount it is" do
    When
    workspace = Dev::Lifecycle::Workspace::Mounted.new(Pathname("/work/snappy"))

    Then
    workspace.is_a?(Dev::Lifecycle::Workspace)
    workspace.path == Pathname("/work/snappy")
    workspace.description == "the checkout, mounted"
  end

  test "mounted workspaces compare by their path, and never equal a snapshot" do
    Given
    snapshot = Dev::Lifecycle::Snapshot.new(sha: SHA, branch: Dev::Lifecycle::SnapshotBranch.mint(runner: "box"))

    Expect
    assert_value_semantics Dev::Lifecycle::Workspace::Mounted.new(Pathname("/work/snappy")),
      equal_to: Dev::Lifecycle::Workspace::Mounted.new(Pathname("/work/snappy")),
      unequal_to: [Dev::Lifecycle::Workspace::Mounted.new(Pathname("/elsewhere/snappy")), Dev::Lifecycle::Workspace::Snapshot.new(snapshot)]
  end

  test "the workspace is sealed and its shapes final: a shape declared elsewhere is refused" do
    When
    declare.call

    Then
    raises RuntimeError

    Where
    declare
    -> { Class.new { include Dev::Lifecycle::Workspace } }
    -> { Class.new(Dev::Lifecycle::Workspace::Snapshot) }
    -> { Class.new(Dev::Lifecycle::Workspace::Mounted) }
  end
end
