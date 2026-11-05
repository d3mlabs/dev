# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::SnapshotCommitTest < Minitest::Test
  test "a dirty tree snapshots to a new commit on HEAD carrying the modified, new and deleted files" do
    Given "a committed repo with a modified file, a new file, a deleted file and an ignored one"
    root = repo_with_commit
    git = Dev::Lifecycle::Git.new(root:)
    head = git.capture(["rev-parse", "HEAD"]).strip
    (root / "a.txt").write("changed\n")
    (root / "new.txt").write("new\n")
    (root / "gone.txt").delete
    (root / ".gitignore").write("*.log\n")
    (root / "noise.log").write("ignored\n")

    When
    sha = Dev::Lifecycle::SnapshotCommit.new(git:).create

    Then "the snapshot is a child of HEAD with the working tree's content; HEAD, the branch and the operator's index are untouched"
    sha != head
    git.capture(["rev-parse", "#{sha}^"]).strip == head
    git.capture(["show", "#{sha}:a.txt"]) == "changed\n"
    git.capture(["show", "#{sha}:new.txt"]) == "new\n"
    git.capture(["show", "#{sha}:.gitignore"]) == "*.log\n"
    git.capture(["ls-tree", "--name-only", sha]).lines.map(&:strip).sort == [".gitignore", "a.txt", "new.txt"]
    git.capture(["log", "-1", "--format=%s %an", sha]).strip == "dev snapshot of the working tree at #{head[0, 12]} dev"
    git.capture(["rev-parse", "HEAD"]).strip == head
    git.capture(["status", "--porcelain"]).lines.map(&:strip).sort == ["?? .gitignore", "?? new.txt", "D gone.txt", "M a.txt"]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a clean tree snapshots to HEAD itself" do
    Given "a committed repo with nothing uncommitted"
    root = repo_with_commit
    git = Dev::Lifecycle::Git.new(root:)
    head = git.capture(["rev-parse", "HEAD"]).strip

    When
    sha = Dev::Lifecycle::SnapshotCommit.new(git:).create

    Then
    sha == head
    git.capture(["rev-list", "--all", "--count"]).strip == "1"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a tracked file that .gitignore also names stays in the snapshot" do
    Given "a repo tracking a file its .gitignore matches"
    root = repo_with_commit
    git = Dev::Lifecycle::Git.new(root:)
    (root / ".gitignore").write("a.txt\n")
    git.capture(["add", ".gitignore"])
    git.capture(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "ignore a"])
    (root / "a.txt").write("still tracked\n")

    When
    sha = Dev::Lifecycle::SnapshotCommit.new(git:).create

    Then
    git.capture(["show", "#{sha}:a.txt"]) == "still tracked\n"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a repository with no commit yet snapshots to a parentless commit" do
    Given "an initialised repo with one file and no commit"
    root = Pathname(Dir.mktmpdir("snapshot-commit-"))
    git = Dev::Lifecycle::Git.new(root:)
    git.capture(["init", "-q"])
    (root / "a.txt").write("a\n")

    When
    sha = Dev::Lifecycle::SnapshotCommit.new(git:).create

    Then
    git.capture(["show", "#{sha}:a.txt"]) == "a\n"
    git.capture(["log", "-1", "--format=%P|%s", sha]).strip == "|dev snapshot of the working tree"
    !git.succeeds?(["rev-parse", "--verify", "--quiet", "HEAD"])

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "outside a checkout there is nothing to snapshot" do
    Given "a plain directory"
    root = Pathname(Dir.mktmpdir("snapshot-commit-"))

    When
    Dev::Lifecycle::SnapshotCommit.new(git: Dev::Lifecycle::Git.new(root:)).create

    Then
    error = raises(Dev::Lifecycle::SnapshotCommit::NotACheckoutError)
    error.message.include?(root.to_s)

    Cleanup
    FileUtils.rm_rf(root)
  end

  private

  def repo_with_commit
    root = Pathname(Dir.mktmpdir("snapshot-commit-"))
    git = Dev::Lifecycle::Git.new(root:)
    git.capture(["init", "-q"])
    (root / "a.txt").write("a\n")
    (root / "gone.txt").write("gone\n")
    git.capture(["add", "a.txt", "gone.txt"])
    git.capture(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "one"])
    root
  end
end
