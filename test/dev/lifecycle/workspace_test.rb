# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle/snapshot"
require "dev/lifecycle/snapshot_branch"
require "dev/lifecycle/workspace"

# What a build host holds of the tree: today one shape, the snapshot the
# sync step pushed, named on the crossing line by its short sha.
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

  test "the workspace is sealed and its snapshot shape final: a shape declared elsewhere is refused" do
    When
    declare.call

    Then
    raises RuntimeError

    Where
    declare
    -> { Class.new { include Dev::Lifecycle::Workspace } }
    -> { Class.new(Dev::Lifecycle::Workspace::Snapshot) }
  end
end
