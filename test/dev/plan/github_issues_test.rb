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
