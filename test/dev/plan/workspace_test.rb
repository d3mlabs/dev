# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/plan"
require "tmpdir"
require "fileutils"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Plan::WorkspaceTest < Minitest::Test
  # A real git repo with an origin remote, so origin resolution runs the real
  # `git` binary instead of a fake.
  def build_repo(dir, remote: "git@github.com:d3mlabs/demo.git")
    project = File.join(dir, "repo")
    FileUtils.mkdir_p(project)
    system("git", "init", "-q", project, exception: true)
    system("git", "-C", project, "remote", "add", "origin", remote, exception: true)
    Pathname.new(project)
  end

  test "origin_repo parses an ssh remote" do
    Given "a repo with an ssh origin"
    dir = Dir.mktmpdir("ai-flow-ws-test-")
    workspace = Dev::Plan::Workspace.new(project_root: build_repo(dir))

    Expect
    workspace.origin_repo == "d3mlabs/demo"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "origin_repo parses an https remote" do
    Given "a repo with an https origin"
    dir = Dir.mktmpdir("ai-flow-ws-test-")
    workspace = Dev::Plan::Workspace.new(
      project_root: build_repo(dir, remote: "https://github.com/d3mlabs/other.git"),
    )

    Expect
    workspace.origin_repo == "d3mlabs/other"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "origin_repo raises for a non-GitHub remote" do
    Given "a repo whose origin is not GitHub"
    dir = Dir.mktmpdir("ai-flow-ws-test-")
    workspace = Dev::Plan::Workspace.new(
      project_root: build_repo(dir, remote: "git@gitlab.com:x/y.git"),
    )

    When "resolving the origin repo"
    workspace.origin_repo

    Then
    raises Dev::Plan::Workspace::Error

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "plan_path follows the gh-<n>-<slug> convention for the origin repo" do
    Given "a workspace"
    dir = Dir.mktmpdir("ai-flow-ws-test-")
    root = build_repo(dir)
    workspace = Dev::Plan::Workspace.new(project_root: root)

    Expect "the conventional path inside .cursor/plans"
    workspace.plan_path("d3mlabs/demo", 42, "Carve System: LOD & Streaming!") ==
      root / ".cursor" / "plans" / "gh-42-carve-system-lod-streaming.plan.md"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "plan_path disambiguates issues from another repo (org-wide plans)" do
    Given "a workspace whose origin differs from the plan's repo"
    dir = Dir.mktmpdir("ai-flow-ws-test-")
    root = build_repo(dir)
    workspace = Dev::Plan::Workspace.new(project_root: root)

    Expect "the filename carries the plans repo name"
    workspace.plan_path("d3mlabs/plans", 7, "Org roadmap") ==
      root / ".cursor" / "plans" / "gh-plans-7-org-roadmap.plan.md"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "linked_plan_files returns only plans carrying an ai-flow header" do
    Given "one linked and one unlinked plan file"
    dir = Dir.mktmpdir("ai-flow-ws-test-")
    root = build_repo(dir)
    plans = root / ".cursor" / "plans"
    FileUtils.mkdir_p(plans)
    linked = plans / "gh-1-linked.plan.md"
    linked.write("<!-- ai-flow\nissue: d3mlabs/demo#1\nsynced_at: 2026-01-01T00:00:00Z\n-->\n# L\n")
    (plans / "draft.plan.md").write("# Draft\n")
    workspace = Dev::Plan::Workspace.new(project_root: root)

    Expect
    workspace.linked_plan_files == [linked]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "linked_plan_files finds a header even when Cursor frontmatter sits above it" do
    Given "a hand-edited linked plan with frontmatter above the ai-flow header"
    dir = Dir.mktmpdir("ai-flow-ws-test-")
    root = build_repo(dir)
    plans = root / ".cursor" / "plans"
    FileUtils.mkdir_p(plans)
    linked = plans / "gh-1-linked.plan.md"
    linked.write(<<~PLAN)
      ---
      name: Local label
      isProject: false
      ---
      <!-- ai-flow
      issue: d3mlabs/demo#1
      synced_at: 2026-01-01T00:00:00Z
      -->
      # L
    PLAN
    workspace = Dev::Plan::Workspace.new(project_root: root)

    Expect
    workspace.linked_plan_files == [linked]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "slugify bounds length and strips symbols" do
    Expect
    Dev::Plan::Workspace.slugify("Héllo,  World! ") == "h-llo-world"
    Dev::Plan::Workspace.slugify("!!!") == "plan"
    Dev::Plan::Workspace.slugify("a" * 100) == "a" * 40

    Cleanup
    nil
  end
end
