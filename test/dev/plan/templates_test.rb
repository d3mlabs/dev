# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/plan"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Plan::TemplatesTest < Minitest::Test
  test "render_mirror wraps the bundle body in GitHub front matter and the dev marker" do
    When "rendering the mirror"
    rendered = Dev::Plan::Templates.render_mirror

    Then "front matter leads, the marker follows, and the bundle body — both halves — is verbatim"
    rendered.start_with?("---\nname: Tech design\n")
    rendered.include?(Dev::Plan::Templates::MARKER)
    rendered.end_with?(Dev::Plan::Templates.bundle_body)
    Dev::Plan::Templates.bundle_body.include?("## Problem / Opportunity")
    Dev::Plan::Templates.bundle_body.include?("## Tech design")
  end

  test "body_of round-trips a rendered mirror back to the bundle body" do
    Expect
    Dev::Plan::Templates.body_of(Dev::Plan::Templates.render_mirror) == Dev::Plan::Templates.bundle_body
  end

  test "body_of strips custom front matter from a repo-owned template" do
    Given "a repo-owned template with its own front matter and no marker"
    content = "---\nname: Custom plan\nabout: Repo flavor.\n---\n\n## Custom section\n\nGuidance.\n"

    Expect
    Dev::Plan::Templates.body_of(content) == "## Custom section\n\nGuidance.\n"
  end

  test "body_of returns front-matter-less content unchanged" do
    Expect
    Dev::Plan::Templates.body_of("## Bare section\n") == "## Bare section\n"
  end

  test "mirrored? detects the dev marker" do
    Expect
    Dev::Plan::Templates.mirrored?(Dev::Plan::Templates.render_mirror) == true
    Dev::Plan::Templates.mirrored?("---\nname: Custom plan\n---\n\n## Custom section\n") == false
  end

  test "stale? flags a marker-carrying mirror that drifted from the bundle" do
    Given "an outdated mirror still carrying the marker"
    outdated = "---\nname: Tech design\n---\n#{Dev::Plan::Templates::MARKER}\n\n## Old section\n"

    Expect "only the drifted mirror is stale — current mirrors and repo-owned templates are not"
    Dev::Plan::Templates.stale?(outdated) == true
    Dev::Plan::Templates.stale?(Dev::Plan::Templates.render_mirror) == false
    Dev::Plan::Templates.stale?("## Repo-owned, no marker\n") == false
  end

  test "mirror_path is the conventional GitHub issue-template location" do
    Expect
    Dev::Plan::Templates.mirror_path("/repo") == Pathname("/repo/.github/ISSUE_TEMPLATE/plan.md")
  end
end
