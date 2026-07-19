# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cd"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Cd::RepoDiscoveryTest < Minitest::Test
  test "discovers git repos under the host/org/repo layout" do
    Given "a src tree with two checkouts"
    root = Dir.mktmpdir("cd-root-")
    make_repo(root, "github.com/d3mlabs/dev")
    make_repo(root, "github.com/d3mlabs/ai-flow")

    When "we discover repos"
    repos = Dev::Cd::RepoDiscovery.new(root: root).repos

    Then "both are found with their path segments"
    repos.map(&:name).sort == ["ai-flow", "dev"]
    repos.map(&:segments).sort == [
      ["github.com", "d3mlabs", "ai-flow"],
      ["github.com", "d3mlabs", "dev"],
    ]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "counts a .git file (worktree checkout) as a repo" do
    Given "a checkout whose .git is a file"
    root = Dir.mktmpdir("cd-root-")
    dir = File.join(root, "github.com", "d3mlabs", "worktree-checkout")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, ".git"), "gitdir: /somewhere/else\n")

    When "we discover repos"
    repos = Dev::Cd::RepoDiscovery.new(root: root).repos

    Then "the worktree checkout is found"
    repos.map(&:name) == ["worktree-checkout"]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "skips plain folders without a .git entry" do
    Given "a tree with a repo and a plain folder"
    root = Dir.mktmpdir("cd-root-")
    make_repo(root, "github.com/d3mlabs/dev")
    FileUtils.mkdir_p(File.join(root, "github.com", "d3mlabs", "notes"))

    When "we discover repos"
    repos = Dev::Cd::RepoDiscovery.new(root: root).repos

    Then "only the git repo is found"
    repos.map(&:name) == ["dev"]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "prunes the walk at a repo: nested checkouts are never descended into" do
    Given "a repo containing a vendored inner repo"
    root = Dir.mktmpdir("cd-root-")
    make_repo(root, "github.com/d3mlabs/outer")
    make_repo(root, "github.com/d3mlabs/outer/vendor/inner")

    When "we discover repos"
    repos = Dev::Cd::RepoDiscovery.new(root: root).repos

    Then "only the outer repo is found"
    repos.map(&:name) == ["outer"]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "bounds the walk depth" do
    Given "a repo buried deeper than the depth bound"
    root = Dir.mktmpdir("cd-root-")
    make_repo(root, "a/b/c/d/e/too-deep")

    When "we discover repos"
    repos = Dev::Cd::RepoDiscovery.new(root: root).repos

    Then "nothing is found"
    repos.empty?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "returns an empty list for a missing root" do
    Given "a root path that does not exist"
    root = File.join(Dir.tmpdir, "cd-missing-#{Process.pid}")

    Expect "discovery yields nothing"
    Dev::Cd::RepoDiscovery.new(root: root).repos.empty?
  end

  test "results are sorted by path regardless of filesystem order" do
    Given "several repos"
    root = Dir.mktmpdir("cd-root-")
    make_repo(root, "github.com/zzz/last")
    make_repo(root, "bitbucket.org/aaa/first")
    make_repo(root, "github.com/mmm/middle")

    When "we discover repos"
    repos = Dev::Cd::RepoDiscovery.new(root: root).repos

    Then "paths come back sorted"
    repos.map { |r| r.segments.join("/") } == [
      "bitbucket.org/aaa/first",
      "github.com/mmm/middle",
      "github.com/zzz/last",
    ]

    Cleanup
    FileUtils.rm_rf(root)
  end

  private

  def make_repo(root, relative_path)
    dir = File.join(root, relative_path)
    FileUtils.mkdir_p(File.join(dir, ".git"))
    dir
  end
end
