# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/plan"

transform!(RSpock::AST::Transformation)
class Dev::Plan::ContentTest < Minitest::Test
  FRONTMATTER = <<~YAML
    ---
    name: Local label
    isProject: false
    ---
  YAML

  test "parse peels header, frontmatter, and markdown body" do
    Given "a linked plan with Cursor frontmatter"
    header = Dev::Plan::Header.new(owner_repo: "d3mlabs/demo", number: 1, synced_at: "2026-01-01T00:00:00Z")
    body = "# Plan title\n\nprose\n"
    raw = "#{header.render}#{FRONTMATTER}#{body}"

    When "parsing it"
    plan = Dev::Plan::Content.parse(raw)

    Then "all three layers are separated"
    plan.header.issue_ref == "d3mlabs/demo#1"
    plan.frontmatter == FRONTMATTER
    plan.body == body

    Cleanup
    nil
  end

  test "render writes canonical header-then-frontmatter-then-body order" do
    Given "frontmatter sitting above the ai-flow header"
    header = Dev::Plan::Header.new(owner_repo: "d3mlabs/demo", number: 2, synced_at: "2026-01-01T00:00:00Z")
    body = "# Title\n"
    raw = "#{FRONTMATTER}#{header.render}#{body}"

    When "parsing and re-rendering"
    plan = Dev::Plan::Content.parse(raw)

    Then "layers are recognized and render normalizes order"
    plan.header.number == 2
    plan.frontmatter == FRONTMATTER
    plan.body == body
    plan.render == "#{header.render}#{FRONTMATTER}#{body}"

    Cleanup
    nil
  end

  test "parse recognizes Cursor's rewrite layout: frontmatter, blank line, header" do
    Given "the exact layout Cursor's plan tool writes for a linked plan"
    header = Dev::Plan::Header.new(owner_repo: "d3mlabs/demo", number: 3, synced_at: "2026-01-01T00:00:00Z")
    body = "# Title\n\nprose\n"
    raw = "#{FRONTMATTER}\n#{header.render}#{body}"

    When "parsing and re-rendering"
    plan = Dev::Plan::Content.parse(raw)

    Then "the header is found past the blank line and render restores canonical order"
    plan.header.issue_ref == "d3mlabs/demo#3"
    plan.frontmatter == FRONTMATTER
    plan.body == body
    plan.render == "#{header.render}#{FRONTMATTER}#{body}"

    Cleanup
    nil
  end

  test "parse tolerates a draft with frontmatter and no ai-flow header" do
    Given "an unlinked Cursor draft"
    body = "# Draft\n"
    raw = "#{FRONTMATTER}#{body}"

    When "parsing it"
    plan = Dev::Plan::Content.parse(raw)

    Then "frontmatter is local-only and the body is markdown"
    plan.header.nil?
    plan.frontmatter == FRONTMATTER
    plan.body == body

    Cleanup
    nil
  end
end
