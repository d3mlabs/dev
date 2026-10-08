# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/skills/layout"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Skills::LayoutTest < Minitest::Test
  test "SHIPPED_SKILLS_DIR points at dev's packaged skills" do
    Expect "the shipped ai-flow skill resolves under it"
    (Dev::Skills::Layout::SHIPPED_SKILLS_DIR / "ai-flow" / "SKILL.md").file?
  end

  test "the user-global root is ~/.cursor/skills" do
    Expect "the root under the given home"
    Dev::Skills::Layout.user_global_root(home: "/home/u") == Pathname("/home/u/.cursor/skills")
  end

  test "the project root is the dev-managed subtree <project>/.agents/skills/dev" do
    Expect "the agent-neutral project dir's dev/ subtree, inside the project skills dir"
    Dev::Skills::Layout.project_skills_dir("/src/repo") == Pathname("/src/repo/.agents/skills")
    Dev::Skills::Layout.project_root("/src/repo") == Pathname("/src/repo/.agents/skills/dev")
    Dev::Skills::Layout.manifest_file("/src/repo/.agents/skills/dev") == Pathname("/src/repo/.agents/skills/dev/manifest.json")
  end

  test "a channel link is <integration>/<package>/<skill>" do
    Expect "the three segments joined"
    Dev::Skills::Layout.channel_link("gem", "rspock", "rspock") == "gem/rspock/rspock"
  end

  test "legacy_gem_links finds the flat gem- symlinks of the old layout and nothing else" do
    Given "a project skills dir with a legacy link, a user link, a user dir, and the dev/ subtree"
    dir = Dir.mktmpdir("dev-skills-layout-test-")
    skills = File.join(dir, ".agents", "skills")
    FileUtils.mkdir_p(File.join(skills, "dev", "gem"))
    FileUtils.mkdir_p(File.join(skills, "gem-looking-dir"))
    File.symlink("/nowhere/rspock", File.join(skills, "gem-rspock--rspock"))
    File.symlink("/nowhere/mine", File.join(skills, "mine"))

    Expect "only the legacy symlink"
    Dev::Skills::Layout.legacy_gem_links(dir) == [Pathname(skills) / "gem-rspock--rspock"]

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
