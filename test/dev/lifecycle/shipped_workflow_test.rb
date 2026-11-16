# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle/shipped_workflow"
require "fileutils"
require "pathname"
require "tmpdir"

# A workflow dev ships as a project carries it: both copies' paths and the
# `cp` that makes the project's, spelled once for every shipped workflow.
transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ShippedWorkflowTest < Minitest::Test
  def setup
    @root = Pathname(Dir.mktmpdir("shipped-workflow-"))
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  test "dev's copy is under share/workflows and the project's under .github/workflows, both by the file name" do
    Given
    workflow = Dev::Lifecycle::ShippedWorkflow.new(file_name: "dev-publish-rubygems.yml", root: @root)

    Expect
    workflow.file_name == "dev-publish-rubygems.yml"
    workflow.source == Dev::Lifecycle::ShippedWorkflow::SHARE_DIR / "dev-publish-rubygems.yml"
    workflow.source.dirname.basename.to_s == "workflows"
    workflow.source.dirname.dirname.basename.to_s == "share"
    workflow.project_path == Pathname(".github/workflows/dev-publish-rubygems.yml")
    workflow.path == @root / ".github" / "workflows" / "dev-publish-rubygems.yml"
  end

  test "installed? is whether the project carries the copy as a file" do
    Given
    workflow = Dev::Lifecycle::ShippedWorkflow.new(file_name: "dev-lifecycle.yml", root: @root)
    missing = workflow.installed?

    When "the copy the instruction names is made"
    workflow.path.dirname.mkpath
    FileUtils.cp(workflow.source, workflow.path)

    Then
    missing == false
    workflow.installed? == true
  end

  test "a directory at the copy's path is not the copy" do
    Given
    workflow = Dev::Lifecycle::ShippedWorkflow.new(file_name: "dev-lifecycle.yml", root: @root)
    workflow.path.mkpath

    Expect
    workflow.installed? == false
  end

  test "the copy instruction is the mkdir and the cp from dev's copy to the project's" do
    Given
    workflow = Dev::Lifecycle::ShippedWorkflow.new(file_name: "dev-publish-rubygems.yml", root: @root)

    Expect
    workflow.copy_instruction ==
      "mkdir -p .github/workflows && cp #{Dev::Lifecycle::ShippedWorkflow::SHARE_DIR}/dev-publish-rubygems.yml .github/workflows/dev-publish-rubygems.yml"
  end
end
