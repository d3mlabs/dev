# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "fileutils"
require "pathname"
require "stringio"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::SnapshotSyncTest < Minitest::Test
  test "sync pushes a snapshot of the dirty tree for the block's duration and deletes the branch after" do
    Given "a checkout with an uncommitted change, a filtered workflow and a bare origin"
    workspace = Pathname(Dir.mktmpdir("snapshot-sync-"))
    root, origin = checkout_with_origin(workspace)
    write_workflow(root, "on:\n  push:\n    branches: [main]\n")
    (root / "a.txt").write("changed\n")
    seen_on_remote = nil
    seen = nil

    When
    result = Dev::Lifecycle::SnapshotSync.new(root:, out: StringIO.new).sync(runner: "cellbound-3d") do |snapshot|
      seen = snapshot
      seen_on_remote = remote_heads(origin)
      :dispatched
    end

    Then "the block ran with the pushed snapshot and returned through sync; the branch is gone after, the checkout as it was"
    result == :dispatched
    seen.branch.runner == "cellbound-3d"
    seen.branch.name.start_with?("dev/build/cellbound-3d/")
    seen_on_remote.fetch(seen.branch.ref) == seen.sha
    Dev::Lifecycle::Git.new(root: origin).capture(["show", "#{seen.sha}:a.txt"]) == "changed\n"
    remote_heads(origin).keys == ["refs/heads/main"]
    (root / "a.txt").read == "changed\n"
    Dev::Lifecycle::Git.new(root:).capture(["status", "--porcelain"]).lines.map(&:strip) == ["M a.txt", "?? .github/"]

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "the branch is deleted when the block raises, and the error is the block's" do
    Given
    workspace = Pathname(Dir.mktmpdir("snapshot-sync-"))
    root, origin = checkout_with_origin(workspace)
    error_class = Class.new(RuntimeError)

    When
    Dev::Lifecycle::SnapshotSync.new(root:, out: StringIO.new).sync(runner: "box") { |_snapshot| raise error_class, "the run failed" }

    Then
    error = raises(error_class)
    error.message == "the run failed"
    remote_heads(origin).keys == ["refs/heads/main"]

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "an unfiltered push trigger refuses before anything is pushed" do
    Given "a checkout whose CI runs on every push"
    workspace = Pathname(Dir.mktmpdir("snapshot-sync-"))
    root, origin = checkout_with_origin(workspace)
    write_workflow(root, "on: push\n")
    ran = false

    When
    Dev::Lifecycle::SnapshotSync.new(root:, out: StringIO.new).sync(runner: "box") { |_snapshot| ran = true }

    Then
    raises(Dev::Lifecycle::WorkflowTriggers::UnfilteredPushTriggerError)
    !ran
    remote_heads(origin).keys == ["refs/heads/main"]

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "a runner label that cannot name a branch refuses before anything is pushed" do
    Given
    workspace = Pathname(Dir.mktmpdir("snapshot-sync-"))
    root, origin = checkout_with_origin(workspace)

    When
    Dev::Lifecycle::SnapshotSync.new(root:, out: StringIO.new).sync(runner: "a/b") { |_snapshot| nil }

    Then
    raises(Dev::Lifecycle::SnapshotBranch::InvalidRunnerLabelError)
    remote_heads(origin).keys == ["refs/heads/main"]

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "a push the origin refuses is a PushError and the block never runs" do
    Given "a checkout whose origin is gone"
    workspace = Pathname(Dir.mktmpdir("snapshot-sync-"))
    root, origin = checkout_with_origin(workspace)
    FileUtils.rm_rf(origin)
    ran = false

    When
    Dev::Lifecycle::SnapshotSync.new(root:, out: StringIO.new).sync(runner: "box") { |_snapshot| ran = true }

    Then
    raises(Dev::Lifecycle::SnapshotBranches::PushError)
    !ran

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "a delete the origin refuses is reported with the prune as the fallback, and the block's result stands" do
    Given "an origin that accepts pushes and refuses deletes"
    workspace = Pathname(Dir.mktmpdir("snapshot-sync-"))
    root, origin = checkout_with_origin(workspace)
    Dev::Lifecycle::Git.new(root: origin).capture(["config", "receive.denyDeletes", "true"])
    out = StringIO.new

    When
    result = Dev::Lifecycle::SnapshotSync.new(root:, out:).sync(runner: "box") { |snapshot| snapshot.branch }

    Then
    remote_heads(origin).keys.include?(result.ref)
    out.string.include?("could not delete #{result} from origin")
    out.string.include?("`dev cache gc` prunes it after 7 days")

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  private

  def checkout_with_origin(workspace)
    origin = workspace / "origin.git"
    root = workspace / "checkout"
    Dev::Lifecycle::Git.new(root: workspace).capture(["init", "-q", "--bare", origin.to_s])
    root.mkpath
    git = Dev::Lifecycle::Git.new(root:)
    git.capture(["init", "-q", "-b", "main"])
    (root / "a.txt").write("a\n")
    git.capture(["add", "a.txt"])
    git.capture(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "one"])
    git.capture(["remote", "add", "origin", origin.to_s])
    git.capture(["push", "-q", "-u", "origin", "main"])
    [root, origin]
  end

  def write_workflow(root, on_block)
    dir = root / ".github" / "workflows"
    dir.mkpath
    (dir / "ci.yml").write("name: CI\n#{on_block}jobs:\n  noop:\n    runs-on: ubuntu-latest\n    steps: []\n")
  end

  def remote_heads(origin)
    Dev::Lifecycle::Git.new(root: origin).capture(["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads/"])
      .lines.to_h { |line| line.strip.split(" ", 2) }
  end
end
