# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cd"
require "tmpdir"
require "fileutils"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Cd::WorkspaceTest < Minitest::Test
  # @param root [String]
  # @param relative [String]
  # @return [Pathname]
  def make_git_repo(root, relative)
    path = Pathname(root) / relative
    FileUtils.mkdir_p(path)
    FileUtils.mkdir_p(path / ".git")
    path
  end

  test "root defaults to ~/src when DEV_CD_ROOT is unset" do
    Given "no DEV_CD_ROOT"
    env = {}

    Expect
    Dev::Cd::Workspace.root(env:) == Pathname("~/src").expand_path
  end

  test "root respects DEV_CD_ROOT" do
    Given "a custom DEV_CD_ROOT"
    env = { "DEV_CD_ROOT" => "/tmp/checkouts" }

    Expect
    Dev::Cd::Workspace.root(env:) == Pathname("/tmp/checkouts")
  end

  test "all discovers github.com org/repo checkouts" do
    Given "a search root with two github.com checkouts"
    dir = Dir.mktmpdir("dev-cd-workspace-")
    make_git_repo(dir, "github.com/d3mlabs/dev")
    make_git_repo(dir, "github.com/other/dev")
    workspace = Dev::Cd::Workspace.new(root: dir)

    When "listing repos"
    repos = workspace.all

    Then "both are found with org/name from the layout"
    repos.map(&:org_repo).sort == ["d3mlabs/dev", "other/dev"]
    repos.map { |r| r.path.basename.to_s }.uniq == ["dev"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "all uses parent/leaf when not under github.com" do
    Given "a flat org/repo tree"
    dir = Dir.mktmpdir("dev-cd-workspace-")
    make_git_repo(dir, "acme/widgets")
    workspace = Dev::Cd::Workspace.new(root: dir)

    Expect
    workspace.all.map(&:org_repo) == ["acme/widgets"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "all ignores non-git directories and does not descend into repos" do
    Given "a git repo with a nested .git under vendor"
    dir = Dir.mktmpdir("dev-cd-workspace-")
    repo = make_git_repo(dir, "github.com/d3mlabs/dev")
    nested = repo / "vendor" / "dep"
    FileUtils.mkdir_p(nested / ".git")
    FileUtils.mkdir_p(Pathname(dir) / "not-a-repo" / "readme")
    workspace = Dev::Cd::Workspace.new(root: dir)

    Expect "only the outer checkout is indexed"
    workspace.all.map { |r| r.path.to_s } == [repo.to_s]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "all returns empty when the search root is missing" do
    Given "a nonexistent root"
    workspace = Dev::Cd::Workspace.new(root: "/tmp/dev-cd-missing-#{Process.pid}")

    Expect
    workspace.all == []
  end

  test "all sorts by path for stable ordering" do
    Given "repos created in reverse path order"
    dir = Dir.mktmpdir("dev-cd-workspace-")
    make_git_repo(dir, "github.com/zeta/app")
    make_git_repo(dir, "github.com/alpha/app")
    workspace = Dev::Cd::Workspace.new(root: dir)

    Expect
    workspace.all.map(&:org_repo) == ["alpha/app", "zeta/app"]

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
