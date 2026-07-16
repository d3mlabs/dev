# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/plan"

transform!(RSpock::AST::Transformation)
class Dev::Plan::HeaderTest < Minitest::Test
  test "split parses the ai-flow header and returns the body" do
    Given "a linked plan file's content"
    content = "<!-- ai-flow\nissue: d3mlabs/cellbound-3d#123\nsynced_at: 2026-07-13T17:41:02Z\n-->\n# Plan title\nbody\n"

    When "splitting it"
    header, body = Dev::Plan::Header.split(content)

    Then "the header fields and body are extracted"
    header.owner_repo == "d3mlabs/cellbound-3d"
    header.number == 123
    header.synced_at == "2026-07-13T17:41:02Z"
    header.issue_ref == "d3mlabs/cellbound-3d#123"
    body == "# Plan title\nbody\n"

    Cleanup
    nil
  end

  test "split returns a nil header for an unlinked plan" do
    Given "content without an ai-flow header"
    content = "# Just a draft\n"

    When "splitting it"
    header, body = Dev::Plan::Header.split(content)

    Then "there is no header and the body is untouched"
    header.nil?
    body == content

    Cleanup
    nil
  end

  test "render round-trips through split" do
    Given "a header"
    header = Dev::Plan::Header.new(owner_repo: "d3mlabs/plans", number: 7, synced_at: "2026-01-01T00:00:00Z")

    When "rendering and re-splitting with a body"
    reparsed, body = Dev::Plan::Header.split(header.render + "# T\n")

    Then "the fields survive"
    reparsed.owner_repo == "d3mlabs/plans"
    reparsed.number == 7
    reparsed.synced_at == "2026-01-01T00:00:00Z"
    body == "# T\n"

    Cleanup
    nil
  end

  test "issue body conversion adds and strips the managed marker" do
    Given "a plan body"
    plan_body = "# Title\n\ncontent\n"

    When "converting to an issue body and back"
    issue_body = Dev::Plan.to_issue_body(plan_body)
    round_tripped = Dev::Plan.from_issue_body(issue_body)

    Then "the marker is appended and then stripped"
    issue_body == "# Title\n\ncontent\n\n<!-- ai-flow:plan -->\n"
    round_tripped == plan_body

    Cleanup
    nil
  end

  test "from_issue_body normalizes CRLF line endings from web edits" do
    Given "an issue body edited via the GitHub web UI"
    issue_body = "# Title\r\n\r\ncontent\r\n\r\n<!-- ai-flow:plan -->"

    Expect "LF-normalized plan body"
    Dev::Plan.from_issue_body(issue_body) == "# Title\n\ncontent\n"

    Cleanup
    nil
  end
end
