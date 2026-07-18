# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/plan"

transform!(RSpock::AST::Transformation)
class Dev::Plan::FrontmatterTest < Minitest::Test
  CURSOR_FRONTMATTER = <<~YAML
    ---
    name: Organic diapedesis deformation
    overview: Improve the squeeze visual
    todos:
      - id: squeeze-angle
        content: Add squeezeAngle to Membrane
        status: completed
    isProject: false
    ---
  YAML

  test "split peels a Cursor YAML frontmatter block from the start" do
    Given "content with Cursor frontmatter then markdown"
    body = "# Plan title\n\nprose\n"
    content = "#{CURSOR_FRONTMATTER}#{body}"

    When "splitting it"
    frontmatter, remainder = Dev::Plan::Frontmatter.split(content)

    Then "the frontmatter is peeled and the markdown body remains"
    frontmatter == CURSOR_FRONTMATTER
    remainder == body

    Cleanup
    nil
  end

  test "split returns nil frontmatter when there is no leading fence" do
    Given "plain markdown"
    content = "# Just a plan\n\nA horizontal rule deeper down:\n\n---\n\nmore\n"

    When "splitting it"
    frontmatter, remainder = Dev::Plan::Frontmatter.split(content)

    Then "nothing is peeled"
    frontmatter.nil?
    remainder == content

    Cleanup
    nil
  end

  test "split leaves a leading --- that is not a YAML mapping alone" do
    Given "a markdown horizontal rule at the top followed by prose"
    content = "---\n\n# Not frontmatter\n"

    When "splitting it"
    frontmatter, remainder = Dev::Plan::Frontmatter.split(content)

    Then "the content is untouched"
    frontmatter.nil?
    remainder == content

    Cleanup
    nil
  end

  test "split leaves malformed YAML between fences alone" do
    Given "fences whose interior is not valid YAML"
    content = "---\n: this is broken [\n---\n# Title\n"

    When "splitting it"
    frontmatter, remainder = Dev::Plan::Frontmatter.split(content)

    Then "the content is untouched"
    frontmatter.nil?
    remainder == content

    Cleanup
    nil
  end

  test "split leaves a YAML sequence (non-mapping) alone" do
    Given "fences whose interior is a YAML list"
    content = "---\n- item\n- other\n---\n# Title\n"

    When "splitting it"
    frontmatter, remainder = Dev::Plan::Frontmatter.split(content)

    Then "the content is untouched"
    frontmatter.nil?
    remainder == content

    Cleanup
    nil
  end
end
