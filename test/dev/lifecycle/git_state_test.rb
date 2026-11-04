# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "fileutils"
require "open3"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::GitStateTest < Minitest::Test
  test "read reports the short sha and a clean tree for a committed checkout" do
    Given "a repo with one commit and nothing else"
    root = Pathname(Dir.mktmpdir("git-state-"))
    git(root, "init", "-q")
    (root / "a.txt").write("a\n")
    git(root, "add", "a.txt")
    git(root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "one")
    head, = Open3.capture2("git", "-C", root.to_s, "rev-parse", "--short=12", "HEAD")

    When
    state = Dev::Lifecycle::GitState.read(root)

    Then
    state.sha == head.strip
    state.sha.length == 12
    !state.dirty
    state.clean?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "read reports dirty for uncommitted changes — modified or untracked" do
    Given "a committed repo with a modified tracked file and an untracked one"
    root = Pathname(Dir.mktmpdir("git-state-"))
    git(root, "init", "-q")
    (root / "a.txt").write("a\n")
    git(root, "add", "a.txt")
    git(root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "one")
    (root / "a.txt").write("b\n")
    (root / "new.txt").write("new\n")

    When
    state = Dev::Lifecycle::GitState.read(root)

    Then
    !state.sha.nil?
    state.dirty
    !state.clean?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "read outside a checkout knows no sha and never trusts the tree as clean" do
    Given "a plain directory"
    root = Pathname(Dir.mktmpdir("git-state-"))
    (root / "a.txt").write("a\n")

    When
    state = Dev::Lifecycle::GitState.read(root)

    Then
    state.sha.nil?
    state.dirty
    !state.clean?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "states are values" do
    Expect
    Dev::Lifecycle::GitState.new(sha: "abc", dirty: false) == Dev::Lifecycle::GitState.new(sha: "abc", dirty: false)
    Dev::Lifecycle::GitState.new(sha: "abc", dirty: false).hash == Dev::Lifecycle::GitState.new(sha: "abc", dirty: false).hash
    Dev::Lifecycle::GitState.new(sha: "abc", dirty: false) != Dev::Lifecycle::GitState.new(sha: "abc", dirty: true)
    Dev::Lifecycle::GitState.new(sha: "abc", dirty: false) != Dev::Lifecycle::GitState.new(sha: "def", dirty: false)
    !Dev::Lifecycle::GitState.new(sha: nil, dirty: true).clean?
  end

  private

  def git(root, *args)
    _out, err, status = Open3.capture3("git", "-C", root.to_s, *args)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?
  end
end
