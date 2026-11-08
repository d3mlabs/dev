# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_container"
require "dev/container_workspace"
require "dev/lifecycle/snapshot"
require "dev/lifecycle/snapshot_branch"
require "pathname"
require "shellwords"

# The container's own checkout (ADR-0008, dev#421): where it lives under
# the container's data root, and the program that brings it to a snapshot
# before becoming the command. Pure: paths and a shell string, no engine.
transform!(RSpock::AST::Transformation)
class Dev::ContainerWorkspaceTest < Minitest::Test
  ROOT = Pathname("/work/snappy")
  SHA = "0123456789abcdef0123456789abcdef01234567"

  test "the workspace lives under the container's data root, keyed like the service container: the checkout's basename and workspace id" do
    When
    workspace = Dev::ContainerWorkspace.new(project_root: ROOT, data_root: "/var/lib/dev")

    Then
    workspace.path == Pathname("/var/lib/dev/workspaces/snappy-#{Dev::BuildContainer.workspace_id(ROOT)}")
    Dev::ContainerWorkspace::RUNNER == "container"
  end

  test "two checkouts of one project get two workspaces: neither can hijack the other's" do
    Expect
    Dev::ContainerWorkspace.new(project_root: Pathname("/a/snappy"), data_root: "/var/lib/dev").path !=
      Dev::ContainerWorkspace.new(project_root: Pathname("/b/snappy"), data_root: "/var/lib/dev").path
  end

  test "the script creates the workspace once, fetches the snapshot branch with gh's credential helper, resets hard to the sha, cleans untracked files but keeps ignored ones, and execs the command" do
    Given "a snapshot and a command with a space to quote"
    branch = Dev::Lifecycle::SnapshotBranch.mint(runner: Dev::ContainerWorkspace::RUNNER)
    snapshot = Dev::Lifecycle::Snapshot.new(sha: SHA, branch:)
    workspace = Dev::ContainerWorkspace.new(project_root: ROOT, data_root: "/var/lib/dev")

    When
    script = workspace.script(snapshot:, repo: "d3mlabs/snappy", argv: ["dev", "build", "win64 dev"])

    Then "set -e first; each step in order; the fetch over HTTPS with the helper gh wires; `git clean -fd` without -x so Intermediate/ and .shadowenv.d/ survive"
    lines = script.lines.map(&:strip)
    lines.first == "set -e"
    lines.include?("mkdir -p #{workspace.path}")
    lines.include?("cd #{workspace.path}")
    lines.include?("[ -d .git ] || git -c advice.defaultBranchName=false init -q")
    script.include?("git -c credential.helper= -c #{Shellwords.escape("credential.helper=!gh auth git-credential")} \\\n")
    lines.include?("fetch -q --no-tags https://github.com/d3mlabs/snappy.git #{branch.ref}")
    lines.include?("git reset -q --hard #{SHA}")
    lines.include?("git clean -qfd")
    lines.last == "exec dev build win64\\ dev"
    lines.index("git reset -q --hard #{SHA}") > lines.index("fetch -q --no-tags https://github.com/d3mlabs/snappy.git #{branch.ref}")
    lines.index("git clean -qfd") > lines.index("git reset -q --hard #{SHA}")
  end

  test "the script quotes a workspace path with a space in it" do
    Given
    branch = Dev::Lifecycle::SnapshotBranch.mint(runner: Dev::ContainerWorkspace::RUNNER)
    snapshot = Dev::Lifecycle::Snapshot.new(sha: SHA, branch:)
    workspace = Dev::ContainerWorkspace.new(project_root: Pathname("/work/my game"), data_root: "/var/lib/dev")

    When
    script = workspace.script(snapshot:, repo: "o/r", argv: ["true"])

    Then
    script.include?("cd #{Shellwords.escape(workspace.path.to_s)}\n")
    workspace.path.to_s.include?("my game-")
  end
end
