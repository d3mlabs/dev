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

  test "parse collapses an empty frontmatter block stacked above the real one" do
    Given "the mangled double-frontmatter layout from dev#60: empty block, then a de-fenced real block, then the header"
    header = Dev::Plan::Header.new(owner_repo: "d3mlabs/plans", number: 13, synced_at: "2026-01-01T00:00:00Z")
    body = "# Self-learning practices loop\n\nprose\n"
    empty_frontmatter = <<~YAML
      ---
      name: ""
      overview: ""
      todos: []
      isProject: false
      ---
    YAML
    real_frontmatter = <<~YAML
      ---

      name: Self-learning practices loop
      overview: Keep practices current
      todos: []
      isProject: false
      ---
    YAML
    raw = "#{empty_frontmatter}\n#{real_frontmatter}\n#{header.render}#{body}"

    When "parsing and re-rendering"
    plan = Dev::Plan::Content.parse(raw)

    Then "the empty block is dropped, all three layers are recovered, and render is canonical"
    plan.header.issue_ref == "d3mlabs/plans#13"
    plan.frontmatter == real_frontmatter
    plan.body == body
    plan.render == "#{header.render}#{real_frontmatter}#{body}"

    Cleanup
    nil
  end

  test "parse keeps a solitary empty frontmatter block on a fresh draft" do
    Given "an unlinked draft whose frontmatter Cursor has not filled in yet"
    empty_frontmatter = <<~YAML
      ---
      name: ""
      overview: ""
      todos: []
      isProject: false
      ---
    YAML
    body = "# Draft\n"
    raw = "#{empty_frontmatter}#{body}"

    When "parsing it"
    plan = Dev::Plan::Content.parse(raw)

    Then "the empty block survives as the draft's frontmatter"
    plan.header.nil?
    plan.frontmatter == empty_frontmatter
    plan.body == body

    Cleanup
    nil
  end

  SESSION_COMMENT = "<!-- 0396ea46-2344-40be-8e3b-e14cb3d4ffa5 -->\n"

  test "parse peels Cursor's session comment above the frontmatter of an unlinked draft (dev#198)" do
    Given "the layout that shipped frontmatter into dev#197's body: session comment, frontmatter, markdown"
    body = "# Linux/WSL engine parity\n\nprose\n"
    raw = "#{SESSION_COMMENT}#{FRONTMATTER}#{body}"

    When "parsing it"
    plan = Dev::Plan::Content.parse(raw)

    Then "the comment is its own local layer and the body starts at the title"
    plan.header.nil?
    plan.session_comment == SESSION_COMMENT
    plan.frontmatter == FRONTMATTER
    plan.body == body

    Cleanup
    nil
  end

  test "render keeps the session comment on disk after the ai-flow header, and parse reads that back" do
    Given "a draft with a session comment that gets linked"
    header = Dev::Plan::Header.new(owner_repo: "d3mlabs/demo", number: 4, synced_at: "2026-01-01T00:00:00Z")
    body = "# Title\n"
    draft = Dev::Plan::Content.parse("#{SESSION_COMMENT}#{FRONTMATTER}#{body}")

    When "adding the header and re-rendering, then parsing the rendered file"
    rendered = draft.with_header(header).render
    reparsed = Dev::Plan::Content.parse(rendered)

    Then "canonical order is header, session comment, frontmatter, body — and every layer survives the round trip"
    rendered == "#{header.render}#{SESSION_COMMENT}#{FRONTMATTER}#{body}"
    reparsed.header.number == 4
    reparsed.session_comment == SESSION_COMMENT
    reparsed.frontmatter == FRONTMATTER
    reparsed.body == body

    Cleanup
    nil
  end

  test "parse does not mistake a body that opens with an ordinary HTML comment for a session comment" do
    Given "a body whose first line is a non-UUID comment"
    body = "<!-- mirrored from dev share/plan-templates/tech-design.md -->\n# Title\n"
    raw = "#{FRONTMATTER}#{body}"

    When "parsing it"
    plan = Dev::Plan::Content.parse(raw)

    Then "the comment stays in the body"
    plan.session_comment.nil?
    plan.body == body

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
