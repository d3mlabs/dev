# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "fileutils"
require "pathname"
require "support/fake_gh"
require "tmpdir"

# The forge's side of a dispatch over a scripted gh: what dev asks, in
# which words, and how each answer is read.
transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::WorkflowRunsTest < Minitest::Test
  QUEUED = { "databaseId" => 42, "url" => "https://github.com/o/r/actions/runs/42", "status" => "queued", "conclusion" => nil }.freeze
  GREEN = QUEUED.merge("status" => "completed", "conclusion" => "success").freeze
  RUN = Dev::Lifecycle::WorkflowRun.new(id: 42, url: "https://github.com/o/r/actions/runs/42", status: "queued", conclusion: nil)

  def setup
    @gh = FakeGh.new
    @slept = []
    @runs = Dev::Lifecycle::WorkflowRuns.new(gh: @gh, sleeper: ->(seconds) { @slept << seconds })
  end

  def branch = Dev::Lifecycle::SnapshotBranch.mint(runner: "box", now: Time.utc(2026, 11, 6, 10, 0, 0), nonce: "abcdef")

  test "dispatch runs the workflow by file on the ref with each input as -f name=value" do
    Given
    @gh.answers(["workflow", "run"], with: "")

    When
    @runs.dispatch(workflow: "dev-lifecycle.yml", ref: branch.name, inputs: { "verbs" => "build x", "runner" => "box", "fetch" => "false" })

    Then
    @gh.calls.map(&:argv) == [
      ["workflow", "run", "dev-lifecycle.yml", "--ref", branch.name, "-f", "verbs=build x", "-f", "runner=box", "-f", "fetch=false"],
    ]
  end

  test "locate lists the one workflow_dispatch run on the snapshot branch and reads it as a run" do
    Given
    @gh.answers(["run", "list"], with: [QUEUED])

    When
    run = @runs.locate(workflow: "dev-lifecycle.yml", branch:)

    Then
    run == RUN
    @gh.calls.first.argv == [
      "run", "list", "--workflow", "dev-lifecycle.yml", "--branch", branch.name, "--event", "workflow_dispatch", "--limit", "1",
      "--json", "databaseId,url,status,conclusion",
    ]
    @slept == []
  end

  test "locate polls while the forge has not listed the run yet, sleeping the interval between attempts" do
    Given "two empty answers before the run appears"
    @gh.answers(["run", "list"], with: []).answers(["run", "list"], with: []).answers(["run", "list"], with: [QUEUED])

    When
    run = @runs.locate(workflow: "dev-lifecycle.yml", branch:)

    Then
    run == RUN
    @gh.calls.size == 3
    @slept == [2, 2]
  end

  test "a run never listed is RunNotListedError after the attempts, naming the workflow, the branch and the window" do
    Given
    Dev::Lifecycle::WorkflowRuns::LOCATE_ATTEMPTS.times { @gh.answers(["run", "list"], with: []) }

    When
    @runs.locate(workflow: "dev-lifecycle.yml", branch:)

    Then
    error = raises(Dev::Lifecycle::WorkflowRuns::RunNotListedError)
    error.message == "GitHub listed no run of dev-lifecycle.yml on #{branch} within 60s of the dispatch — look at the workflow's Actions page"
    @slept.size == Dev::Lifecycle::WorkflowRuns::LOCATE_ATTEMPTS - 1
  end

  test "watch streams `gh run watch` to the terminal, then reads the verdict back" do
    Given
    @gh.answers(["run", "watch"], with: "").answers(["run", "view"], with: GREEN)

    When
    finished = @runs.watch(RUN)

    Then
    finished.succeeded?
    @gh.calls.map(&:argv) == [["run", "watch", "42"], ["run", "view", "42", "--json", "databaseId,url,status,conclusion"]]
  end

  test "a watch gh drops is WatchLostError naming the run's page; the verdict is not read" do
    Given
    @gh.refuses(["run", "watch"], with: "connection reset")

    When
    @runs.watch(RUN)

    Then
    error = raises(Dev::Lifecycle::WorkflowRuns::WatchLostError)
    error.message.start_with?("lost the watch on https://github.com/o/r/actions/runs/42 (")
    error.message.end_with?("); the run continues on GitHub")
    @gh.calls.size == 1
  end

  test "download creates the directory and fetches the named artifact into it" do
    Given
    dir = Pathname(Dir.mktmpdir("workflow-runs-"))
    into = dir / "store" / "rspock"
    @gh.answers(["run", "download"], with: "")

    When
    @runs.download(RUN, name: "rspock", into:)

    Then
    into.directory?
    @gh.calls.first.argv == ["run", "download", "42", "--name", "rspock", "--dir", into.to_s]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an answer that is not JSON is MalformedRunError: #{what}" do
    Given
    @gh.answers(prefix, with: "<html>rate limited</html>")

    When
    call.call(@runs)

    Then
    raises Dev::Lifecycle::WorkflowRuns::MalformedRunError

    Where
    what     | prefix          | call
    "list"   | ["run", "list"] | ->(runs) { runs.locate(workflow: "dev-lifecycle.yml", branch: Dev::Lifecycle::SnapshotBranch.mint(runner: "box")) }
    "view"   | ["run", "view"] | ->(runs) { runs.view(RUN) }
  end

  test "a listed record that is not a run object is MalformedRunError" do
    Given
    @gh.answers(["run", "list"], with: [42])

    When
    @runs.locate(workflow: "dev-lifecycle.yml", branch:)

    Then
    error = raises(Dev::Lifecycle::WorkflowRuns::MalformedRunError)
    error.message == "gh answered with 42, not a run"
  end

  test "a conclusion the forge leaves empty reads as none" do
    Given
    @gh.answers(["run", "view"], with: QUEUED.merge("conclusion" => ""))

    Expect
    @runs.view(RUN).conclusion.nil?
  end
end
