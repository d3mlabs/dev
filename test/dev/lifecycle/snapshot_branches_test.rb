# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "fileutils"
require "pathname"
require "stringio"
require "time"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::SnapshotBranchesTest < Minitest::Test
  WEEK = 7 * 24 * 60 * 60

  test "push lands a commit on its branch at origin without moving HEAD or the local branches" do
    Given "a checkout with a bare origin and a commit reachable from no ref"
    workspace = Pathname(Dir.mktmpdir("snapshot-branches-"))
    root, origin = checkout_with_origin(workspace)
    git = Dev::Lifecycle::Git.new(root:)
    (root / "a.txt").write("changed\n")
    sha = Dev::Lifecycle::SnapshotCommit.new(git:).create
    branch = Dev::Lifecycle::SnapshotBranch.mint(runner: "cellbound-3d", now: Time.utc(2026, 11, 5), nonce: "a1b2c3")

    When
    Dev::Lifecycle::SnapshotBranches.new(git:, out: StringIO.new).push(sha, branch)

    Then
    remote_heads(origin) == { "refs/heads/main" => git.capture(["rev-parse", "HEAD"]).strip, branch.ref => sha }
    git.capture(["branch", "--list"]).strip == "* main"

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "a push the remote refuses is a PushError with git's reason" do
    Given "a checkout whose origin does not exist"
    workspace = Pathname(Dir.mktmpdir("snapshot-branches-"))
    root, origin = checkout_with_origin(workspace)
    FileUtils.rm_rf(origin)
    git = Dev::Lifecycle::Git.new(root:)
    branch = Dev::Lifecycle::SnapshotBranch.mint(runner: "r", nonce: "a1b2c3")

    When
    Dev::Lifecycle::SnapshotBranches.new(git:, out: StringIO.new).push(git.capture(["rev-parse", "HEAD"]).strip, branch)

    Then
    error = raises(Dev::Lifecycle::SnapshotBranches::PushError)
    error.message.include?("could not push the snapshot to origin as #{branch}")

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "list reads every snapshot branch on origin and leaves a hand-made name under the namespace out" do
    Given "an origin with two snapshot branches and a stray dev/build/foo"
    workspace = Pathname(Dir.mktmpdir("snapshot-branches-"))
    root, origin = checkout_with_origin(workspace)
    git = Dev::Lifecycle::Git.new(root:)
    head = git.capture(["rev-parse", "HEAD"]).strip
    older = Dev::Lifecycle::SnapshotBranch.mint(runner: "box", now: Time.utc(2026, 10, 1), nonce: "000001")
    newer = Dev::Lifecycle::SnapshotBranch.mint(runner: "hosted", now: Time.utc(2026, 11, 5), nonce: "000002")
    git.capture(["push", "-q", "origin", "#{head}:#{older.ref}", "#{head}:#{newer.ref}", "#{head}:refs/heads/dev/build/foo"])
    _ = origin

    When
    listed = Dev::Lifecycle::SnapshotBranches.new(git:, out: StringIO.new).list

    Then
    listed.sort_by(&:name) == [older, newer]

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "list over an origin it cannot reach is a ListError naming the namespace" do
    Given "a checkout whose origin is gone"
    workspace = Pathname(Dir.mktmpdir("snapshot-branches-"))
    root, origin = checkout_with_origin(workspace)
    FileUtils.rm_rf(origin)

    When
    Dev::Lifecycle::SnapshotBranches.new(git: Dev::Lifecycle::Git.new(root:), out: StringIO.new).list

    Then
    error = raises(Dev::Lifecycle::SnapshotBranches::ListError)
    error.message.start_with?("could not list dev/build/* on origin")

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "delete the origin refuses is a DeleteError naming the branches" do
    Given "an origin that refuses deletes, holding one snapshot branch"
    workspace = Pathname(Dir.mktmpdir("snapshot-branches-"))
    root, origin = checkout_with_origin(workspace)
    git = Dev::Lifecycle::Git.new(root:)
    branch = Dev::Lifecycle::SnapshotBranch.mint(runner: "box", nonce: "000001")
    git.capture(["push", "-q", "origin", "#{git.capture(["rev-parse", "HEAD"]).strip}:#{branch.ref}"])
    Dev::Lifecycle::Git.new(root: origin).capture(["config", "receive.denyDeletes", "true"])

    When
    Dev::Lifecycle::SnapshotBranches.new(git:, out: StringIO.new).delete([branch])

    Then
    error = raises(Dev::Lifecycle::SnapshotBranches::DeleteError)
    error.message.start_with?("could not delete #{branch} from origin")

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "prune deletes the branches older than the retention, reports each and keeps the rest" do
    Given "an origin with an expired, a fresh and a boundary snapshot branch"
    workspace = Pathname(Dir.mktmpdir("snapshot-branches-"))
    root, origin = checkout_with_origin(workspace)
    git = Dev::Lifecycle::Git.new(root:)
    head = git.capture(["rev-parse", "HEAD"]).strip
    now = Time.utc(2026, 11, 12, 12, 0, 0)
    expired = Dev::Lifecycle::SnapshotBranch.mint(runner: "box", now: now - WEEK - 1, nonce: "000001")
    boundary = Dev::Lifecycle::SnapshotBranch.mint(runner: "box", now: now - WEEK, nonce: "000002")
    fresh = Dev::Lifecycle::SnapshotBranch.mint(runner: "hosted", now: now - 60, nonce: "000003")
    git.capture(["push", "-q", "origin", *[expired, boundary, fresh].map { |branch| "#{head}:#{branch.ref}" }])
    out = StringIO.new

    When
    deleted = Dev::Lifecycle::SnapshotBranches.new(git:, out:).prune(now:)

    Then
    deleted == [expired]
    remote_heads(origin).keys.sort == ["refs/heads/main", boundary.ref, fresh.ref].sort
    out.string == ">>> gc: removed snapshot branch #{expired} from origin\n"

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "prune with nothing expired deletes nothing and says nothing" do
    Given "an origin with one fresh snapshot branch"
    workspace = Pathname(Dir.mktmpdir("snapshot-branches-"))
    root, origin = checkout_with_origin(workspace)
    git = Dev::Lifecycle::Git.new(root:)
    fresh = Dev::Lifecycle::SnapshotBranch.mint(runner: "hosted", nonce: "000003")
    git.capture(["push", "-q", "origin", "#{git.capture(["rev-parse", "HEAD"]).strip}:#{fresh.ref}"])
    out = StringIO.new

    When
    deleted = Dev::Lifecycle::SnapshotBranches.new(git:, out:).prune

    Then
    deleted == []
    remote_heads(origin).key?(fresh.ref)
    out.string == ""

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "prune over an origin it cannot list is reported and skipped, never a failure" do
    Given "a checkout whose origin is gone"
    workspace = Pathname(Dir.mktmpdir("snapshot-branches-"))
    root, origin = checkout_with_origin(workspace)
    FileUtils.rm_rf(origin)
    out = StringIO.new

    When
    deleted = Dev::Lifecycle::SnapshotBranches.new(git: Dev::Lifecycle::Git.new(root:), out:).prune

    Then
    deleted == []
    out.string.start_with?(">>> gc: skipping snapshot branches — could not list dev/build/* on origin")

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "prune over an origin it cannot write is reported and skipped" do
    Given "an origin holding an expired branch, that refuses deletes"
    workspace = Pathname(Dir.mktmpdir("snapshot-branches-"))
    root, origin = checkout_with_origin(workspace)
    git = Dev::Lifecycle::Git.new(root:)
    expired = Dev::Lifecycle::SnapshotBranch.mint(runner: "box", now: Time.utc(2020, 1, 1), nonce: "000001")
    git.capture(["push", "-q", "origin", "#{git.capture(["rev-parse", "HEAD"]).strip}:#{expired.ref}"])
    Dev::Lifecycle::Git.new(root: origin).capture(["config", "receive.denyDeletes", "true"])
    out = StringIO.new

    When
    deleted = Dev::Lifecycle::SnapshotBranches.new(git:, out:).prune

    Then
    deleted == []
    out.string.start_with?(">>> gc: skipping snapshot branches — could not delete #{expired} from origin")
    remote_heads(origin).key?(expired.ref)

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "delete with no branches asks the remote nothing" do
    Given "a checkout whose origin is gone"
    workspace = Pathname(Dir.mktmpdir("snapshot-branches-"))
    root, origin = checkout_with_origin(workspace)
    FileUtils.rm_rf(origin)

    When
    Dev::Lifecycle::SnapshotBranches.new(git: Dev::Lifecycle::Git.new(root:), out: StringIO.new).delete([])

    Then "no DeleteError, although the origin is unreachable"
    true

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "the retention is seven days" do
    Expect
    Dev::Lifecycle::SnapshotBranches::MAX_AGE_DAYS == 7
    Dev::Lifecycle::SnapshotBranches::MAX_AGE == WEEK
  end

  private

  # A checkout with one commit on `main`, pushed to a bare `origin` beside it.
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

  def remote_heads(origin)
    Dev::Lifecycle::Git.new(root: origin).capture(["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads/"])
      .lines.to_h { |line| line.strip.split(" ", 2) }
  end
end
