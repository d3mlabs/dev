# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "time"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::SnapshotTest < Minitest::Test
  test "a snapshot is a value over its sha and branch, with the short sha the crossing line prints" do
    Given
    branch = Dev::Lifecycle::SnapshotBranch.mint(runner: "r", now: Time.utc(2026, 11, 5), nonce: "a1b2c3")
    sha = "3f2a1c9d8e7b6a5f4c3d2e1f0a9b8c7d6e5f4a3b"
    snapshot = Dev::Lifecycle::Snapshot.new(sha:, branch:)

    Expect
    snapshot.short_sha == "3f2a1c9d8e7b"
    snapshot == Dev::Lifecycle::Snapshot.new(sha:, branch:)
    snapshot.eql?(Dev::Lifecycle::Snapshot.new(sha:, branch:))
    snapshot.hash == Dev::Lifecycle::Snapshot.new(sha:, branch:).hash
    snapshot != Dev::Lifecycle::Snapshot.new(sha: "0" * 40, branch:)
    snapshot != Dev::Lifecycle::Snapshot.new(sha:, branch: Dev::Lifecycle::SnapshotBranch.mint(runner: "s", nonce: "a1b2c3"))
    snapshot.ref == branch.ref
    snapshot.pushed?
  end

  test "a checked-out snapshot is the forge's own ref with no branch: what an Actions job hands its container" do
    Given
    sha = "3f2a1c9d8e7b6a5f4c3d2e1f0a9b8c7d6e5f4a3b"
    snapshot = Dev::Lifecycle::Snapshot.checked_out(sha:, ref: "refs/pull/338/merge")

    Expect
    snapshot.ref == "refs/pull/338/merge"
    snapshot.branch.nil?
    !snapshot.pushed?
    snapshot == Dev::Lifecycle::Snapshot.checked_out(sha:, ref: "refs/pull/338/merge")
    snapshot != Dev::Lifecycle::Snapshot.checked_out(sha:, ref: "refs/heads/main")
  end

  test "a snapshot is either pushed to a branch or checked out at a ref, never neither or both" do
    When "a snapshot is made with neither, and with both"
    neither = assert_raises(ArgumentError) { Dev::Lifecycle::Snapshot.new(sha: "0" * 40) }
    both = assert_raises(ArgumentError) do
      Dev::Lifecycle::Snapshot.new(sha: "0" * 40, ref: "refs/heads/main",
        branch: Dev::Lifecycle::SnapshotBranch.mint(runner: "r", nonce: "a1b2c3"))
    end

    Then "each refusal names the rule"
    neither.message.include?("branch it was pushed to or the ref")
    both.message.include?("not both")
  end
end
