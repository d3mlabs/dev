# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/plan"
require "json"

# Records gh invocations and replays canned responses, mirroring
# RunnerSetupTest's RecordingExecutor pattern for the CLI boundary.
class RecordingPlanExecutor
  attr_reader :calls

  def initialize(responses)
    @responses = responses
    @calls = []
  end

  def capture(*argv, stdin: nil)
    @calls << { argv: argv, stdin: stdin }
    @responses.shift || ["", "unexpected call: #{argv.inspect}", false]
  end
end unless defined?(RecordingPlanExecutor)

transform!(RSpock::AST::Transformation)
class Dev::Plan::GithubIssuesTest < Minitest::Test
  ISSUE_JSON = JSON.generate(
    number: 5, title: "T", body: "B", updated_at: "2026-07-13T00:00:01Z",
    html_url: "https://github.com/d3mlabs/demo/issues/5",
  )

  test "get fetches and parses the issue" do
    Given "an executor replaying a gh api response"
    executor = RecordingPlanExecutor.new([[ISSUE_JSON, "", true]])
    issues = Dev::Plan::GithubIssues.new(executor: executor)

    When "getting the issue"
    issue = issues.get("d3mlabs/demo", 5)

    Then "the fields are parsed and gh was called with the issue path"
    issue.number == 5
    issue.updated_at == "2026-07-13T00:00:01Z"
    executor.calls.fetch(0)[:argv] == ["gh", "api", "repos/d3mlabs/demo/issues/5"]

    Cleanup
    nil
  end

  test "update PATCHes with the body as a stdin JSON payload (never argv)" do
    Given "an executor replaying a gh api response"
    executor = RecordingPlanExecutor.new([[ISSUE_JSON, "", true]])
    issues = Dev::Plan::GithubIssues.new(executor: executor)

    When "updating the issue body"
    issues.update("d3mlabs/demo", 5, body: "new body")

    Then "the request is a PATCH with --input - and the JSON on stdin"
    call = executor.calls.fetch(0)
    call[:argv] == ["gh", "api", "-X", "PATCH", "--input", "-", "repos/d3mlabs/demo/issues/5"]
    JSON.parse(call[:stdin]) == { "body" => "new body" }

    Cleanup
    nil
  end

  test "repo_file fetches raw content from the repo's default branch" do
    Given "an executor replaying a raw-content response"
    executor = RecordingPlanExecutor.new([["## Problem\n", "", true]])
    issues = Dev::Plan::GithubIssues.new(executor: executor)

    When "fetching the file"
    content = issues.repo_file("d3mlabs/plans", ".github/ISSUE_TEMPLATE/plan.md")

    Then "the raw content comes back and gh was asked for the raw media type"
    content == "## Problem\n"
    executor.calls.fetch(0)[:argv] == [
      "gh", "api", "-H", "Accept: application/vnd.github.raw",
      "repos/d3mlabs/plans/contents/.github/ISSUE_TEMPLATE/plan.md"
    ]

    Cleanup
    nil
  end

  test "repo_file returns nil when the file is missing or gh fails" do
    Given "an executor replaying a gh failure"
    executor = RecordingPlanExecutor.new([["", "gh: Not Found (HTTP 404)", false]])
    issues = Dev::Plan::GithubIssues.new(executor: executor)

    When "fetching a missing file"
    content = issues.repo_file("d3mlabs/plans", ".github/ISSUE_TEMPLATE/plan.md")

    Then "absence maps to nil, never an error"
    content.nil?

    Cleanup
    nil
  end

  test "an unauthenticated gh maps to an actionable error" do
    Given "an executor replaying gh's auth failure"
    executor = RecordingPlanExecutor.new([["", "To get started with GitHub CLI, please run:  gh auth login", false]])
    issues = Dev::Plan::GithubIssues.new(executor: executor)

    When "getting an issue"
    issues.get("d3mlabs/demo", 5)

    Then
    raises Dev::Plan::GithubIssues::Error

    Cleanup
    nil
  end
end
