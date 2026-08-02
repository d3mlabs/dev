# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/learnings"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Learnings::LayoutTest < Minitest::Test
  test "the repo tier lives inside the repo's .cursor tree" do
    Given "a repo root"
    root = Pathname("/some/repo")

    Expect "the index rule and the detail skills resolve under .cursor"
    Dev::Learnings::Layout.repo_index_file(root) == Pathname("/some/repo/.cursor/rules/learnings-index.mdc")
    Dev::Learnings::Layout.repo_skill_file(root, "some-lesson") ==
      Pathname("/some/repo/.cursor/skills/learnings/some-lesson/SKILL.md")
  end

  test "the org tier lives at the knowledge repo's root" do
    Given "a knowledge repo root"
    root = Pathname("/some/knowledge")

    Expect "the index and the skills corpus resolve beside each other"
    Dev::Learnings::Layout.org_index_file(root) == Pathname("/some/knowledge/index.md")
    Dev::Learnings::Layout.org_skills_dir(root) == Pathname("/some/knowledge/skills")
    Dev::Learnings::Layout.org_skill_file(root, "some-skill") == Pathname("/some/knowledge/skills/some-skill/SKILL.md")
  end

  test "path helpers accept plain string roots and return Pathnames" do
    Expect
    Dev::Learnings::Layout.repo_index_file("/some/repo") == Pathname("/some/repo/.cursor/rules/learnings-index.mdc")
    Dev::Learnings::Layout.org_index_file("/some/knowledge") == Pathname("/some/knowledge/index.md")
  end

  test "the repo scaffold is a canonical always-on index with no entries" do
    Given "the repo-tier template"
    scaffold = Dev::Learnings::Layout::REPO_INDEX_SCAFFOLD

    Expect "front matter, capture/curation preamble, soft cap, and org-tier trailer — no entry lines"
    scaffold.start_with?("---\n")
    scaffold.include?("description:")
    scaffold.include?("alwaysApply: true")
    scaffold.include?("capture-learning")
    scaffold.include?("Soft cap ~50 entries")
    scaffold.include?("## org tier")
    !scaffold.match?(/^- \[/)
  end

  test "the org scaffold carries the fixed section structure dev parses" do
    Given "the org-tier template"
    scaffold = Dev::Learnings::Layout::ORG_INDEX_SCAFFOLD

    Expect "both fixed headings, invariants first, with no entry lines"
    scaffold.include?("## Invariants (always-on)")
    scaffold.include?("## Knowledge (on-demand)")
    scaffold.index("## Invariants (always-on)") < scaffold.index("## Knowledge (on-demand)")
    !scaffold.match?(/^- \[/)
  end
end
