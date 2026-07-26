# typed: false
# frozen_string_literal: true

require "test_helper"
require "pathname"

# Content lint for the committed learnings corpus: the always-on index
# (.cursor/rules/learnings-index.mdc) and the detail skills it points at
# must stay consistent with the format the index defines — pointers
# resolve, skill names match their folders, detail skills stay within the
# line cap.
transform!(RSpock::AST::Transformation)
class Dev::LearningsIndexTest < Minitest::Test
  REPO_ROOT = Pathname(DEV_ROOT)
  INDEX_FILE = REPO_ROOT / ".cursor" / "rules" / "learnings-index.mdc"
  SKILLS_ROOT = REPO_ROOT / ".cursor" / "skills"

  # The format's hard cap for detail skills; a learning outgrowing it
  # graduates to a full skill instead of growing further.
  DETAIL_SKILL_LINE_CAP = 40

  test "the learnings index is an always-on rule" do
    Expect "the frontmatter marks the rule alwaysApply"
    INDEX_FILE.read.include?("alwaysApply: true")
  end

  test "every repo-local index pointer resolves to a committed detail skill" do
    Given "the .cursor/skills pointers in the index (channel-installed pointers are gitignored links, invisible in a fresh checkout)"
    pointers = INDEX_FILE.read.scan(%r{→ (\.cursor/skills/[\w\-/]+)}).flatten

    Expect "each pointer names a committed SKILL.md"
    !pointers.empty?
    pointers.all? { |pointer| (REPO_ROOT / pointer / "SKILL.md").file? }
  end

  test "every committed detail skill is indexed" do
    Given "the committed detail skill directories and the index body"
    skill_dirs = SKILLS_ROOT.glob("*/*/SKILL.md").map(&:dirname)
    index = INDEX_FILE.read

    Expect "each skill directory appears as an index pointer"
    !skill_dirs.empty?
    skill_dirs.all? { |dir| index.include?("#{dir.relative_path_from(REPO_ROOT)}/") }
  end

  test "detail skills name their folder and stay within the line cap" do
    Given "the committed detail skills"
    skill_files = SKILLS_ROOT.glob("*/*/SKILL.md")

    Expect "each frontmatter name matches its folder, and each stays within the cap"
    skill_files.all? { |file| file.read.include?("name: #{file.dirname.basename}") }
    skill_files.all? { |file| file.readlines.size <= DETAIL_SKILL_LINE_CAP }
  end
end
