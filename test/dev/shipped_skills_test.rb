# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/skills/layout"
require "pathname"

# Content lint for dev's own shipped skills (share/cursor-skills): each
# lands user-globally under its folder name, so the frontmatter name must
# match the folder and carry the description Cursor lists it by; and the
# learnings index entries that point into the shipped set by skill name
# must name a skill that is actually shipped.
transform!(RSpock::AST::Transformation)
class Dev::ShippedSkillsTest < Minitest::Test
  REPO_ROOT = Pathname(DEV_ROOT)
  INDEX_FILE = REPO_ROOT / ".cursor" / "rules" / "learnings-index.mdc"
  SHIPPED_SKILLS_DIR = Dev::Skills::Layout::SHIPPED_SKILLS_DIR

  # An index pointer by skill name whose parenthetical places the skill in
  # dev's shipped set, e.g. `→ skill: two-identity-rule (ships in dev's
  # share/cursor-skills; …)`.
  SHIPPED_POINTER = %r{→ skill: ([\w-]+) \([^)]*share/cursor-skills}

  test "every shipped skill names its folder and carries a description" do
    Given "the shipped skill files"
    skill_files = Dev::Skills::Layout.skill_dirs(SHIPPED_SKILLS_DIR).map { |dir| dir / Dev::Skills::Layout::SKILL_FILE }

    Expect "each frontmatter name matches its folder, and each has a description"
    !skill_files.empty?
    skill_files.all? { |file| file.read.include?("name: #{file.dirname.basename}") }
    skill_files.all? { |file| file.read.include?("description:") }
  end

  test "every index pointer into the shipped set resolves to a shipped skill" do
    Given "the index pointers that place their skill in share/cursor-skills"
    pointed_names = INDEX_FILE.read.scan(SHIPPED_POINTER).flatten

    Expect "each names a shipped SKILL.md"
    !pointed_names.empty?
    pointed_names.all? { |name| (SHIPPED_SKILLS_DIR / name / Dev::Skills::Layout::SKILL_FILE).file? }
  end
end
