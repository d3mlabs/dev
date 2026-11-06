# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "fileutils"
require "pathname"
require "tmpdir"
require "yaml"

# The contract between dev and the generic workflow it ships: the file
# name, the inputs, and that the shipped file honours them.
transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::LifecycleWorkflowTest < Minitest::Test
  def setup
    @root = Pathname(Dir.mktmpdir("lifecycle-workflow-"))
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  test "the project's copy lives at .github/workflows/dev-lifecycle.yml; dev's own is under share/workflows and exists" do
    Given
    workflow = Dev::Lifecycle::LifecycleWorkflow.new(root: @root)

    Expect
    workflow.path == @root / ".github" / "workflows" / "dev-lifecycle.yml"
    Dev::Lifecycle::LifecycleWorkflow::SOURCE.file?
    Dev::Lifecycle::LifecycleWorkflow::SOURCE.basename.to_s == "dev-lifecycle.yml"
  end

  test "a project without the copy is refused with the copy named, source included" do
    Given
    workflow = Dev::Lifecycle::LifecycleWorkflow.new(root: @root)

    When
    workflow.assert_installed!

    Then
    error = raises(Dev::Lifecycle::LifecycleWorkflow::WorkflowMissingError)
    error.message == "#{@root} has no .github/workflows/dev-lifecycle.yml: the remote dispatch runs dev's generic workflow from the " \
      "project's checkout — copy it in and commit it (mkdir -p .github/workflows && cp #{Dev::Lifecycle::LifecycleWorkflow::SOURCE} " \
      ".github/workflows/dev-lifecycle.yml)"
  end

  test "a project carrying the copy is ready" do
    Given "the copy the refusal names"
    workflow = Dev::Lifecycle::LifecycleWorkflow.new(root: @root)
    workflow.path.dirname.mkpath
    FileUtils.cp(Dev::Lifecycle::LifecycleWorkflow::SOURCE, workflow.path)

    When
    workflow.assert_installed!

    Then "nothing raised"
    workflow.path.file?
  end

  test "the inputs are the invocation as one verbs entry, the label, and fetch as the word the workflow's boolean input reads: #{what}" do
    Given
    workflow = Dev::Lifecycle::LifecycleWorkflow.new(root: @root)

    Expect
    workflow.inputs(Dev::Lifecycle::VerbInvocation.new(words: ["package", "x", "--no-build"], fetch:), runner: "box") ==
      { "verbs" => "package x --no-build", "runner" => "box", "fetch" => expected }

    Where
    what          | fetch                                                                | expected
    "no fetch"    | nil                                                                  | "false"
    "with fetch"  | Dev::Lifecycle::ArtifactFetch.new(name: "x", into: Pathname("/s/x")) | "true"
  end

  test "the shipped workflow runs on workflow_dispatch alone, declares exactly the inputs dev sends, and runs on the self-hosted runners carrying the label" do
    Given
    shipped = YAML.safe_load(Dev::Lifecycle::LifecycleWorkflow::SOURCE.read)
    triggers = shipped.fetch(true) # YAML 1.1 reads a bare `on:` key as the boolean
    inputs = triggers.fetch("workflow_dispatch").fetch("inputs")
    job = shipped.fetch("jobs").values.first

    Expect
    triggers.keys == ["workflow_dispatch"]
    inputs.keys.sort == ["fetch", "runner", "verbs"]
    inputs.fetch("verbs").fetch("required")
    inputs.fetch("runner").fetch("required")
    inputs.fetch("fetch").fetch("type") == "boolean"
    inputs.fetch("fetch").fetch("default") == false
    job.fetch("runs-on") == ["self-hosted", "${{ inputs.runner }}"]
    job.fetch("steps").map { |step| step["uses"] }.compact == ["actions/checkout@v4", "actions/upload-artifact@v4"]
    job.fetch("steps").any? { |step| step["id"] == "verbs" && step.dig("env", "DEV_LIFECYCLE_VERBS") == "${{ inputs.verbs }}" }
    job.fetch("steps").last.fetch("with").fetch("name") == "${{ steps.verbs.outputs.artifact }}"
    job.fetch("steps").last.fetch("with").fetch("path") == "${{ steps.verbs.outputs.artifact_files }}"
  end
end
