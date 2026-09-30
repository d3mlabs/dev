# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev"
require "dev/workspace_root"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::WorkspaceRootTest < Minitest::Test
  test "the workspace root prefers the nearest dev.yml over an outer git root" do
    Given "a git checkout with a dev.yml project nested inside it"
    root = Dir.mktmpdir("workspace-root-")
    FileUtils.mkdir_p(File.join(root, ".git"))
    project = File.join(root, "sub")
    FileUtils.mkdir_p(File.join(project, "deep"))
    File.write(File.join(project, "dev.yml"), "name: sub\n")

    When "we resolve from the deepest directory"
    resolved = Dir.chdir(File.join(project, "deep")) do
      { workspace: Dev::WorkspaceRoot.workspace, project: Dev::WorkspaceRoot.enclosing_project }
    end

    Then "both point at the dev.yml project"
    resolved[:workspace] == Pathname.new(project).realpath
    resolved[:project] == Pathname.new(project).realpath

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a plain git checkout (no dev.yml) is its own workspace and project" do
    Given "a checkout with only a .git dir"
    root = Dir.mktmpdir("workspace-root-")
    FileUtils.mkdir_p(File.join(root, ".git", "x"))
    FileUtils.mkdir_p(File.join(root, "nested"))

    When "we resolve from a nested directory"
    resolved = Dir.chdir(File.join(root, "nested")) do
      { workspace: Dev::WorkspaceRoot.workspace, project: Dev::WorkspaceRoot.enclosing_project }
    end

    Then "the git root is both"
    resolved[:workspace] == Pathname.new(root).realpath
    resolved[:project] == Pathname.new(root).realpath

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "outside any project the workspace is the cwd and there is no enclosing project" do
    Given "a bare directory"
    cwd = Dir.mktmpdir("workspace-root-")

    When "we resolve from it"
    resolved = Dir.chdir(cwd) do
      { workspace: Dev::WorkspaceRoot.workspace, project: Dev::WorkspaceRoot.enclosing_project }
    end

    Then "the workspace falls back to the cwd; the project is nil"
    resolved[:workspace] == Pathname.new(cwd).realpath
    resolved[:project].nil?

    Cleanup
    FileUtils.rm_rf(cwd)
  end
end
