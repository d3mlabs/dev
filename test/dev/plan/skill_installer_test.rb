# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/plan"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class Dev::Plan::SkillInstallerTest < Minitest::Test
  def build_dirs(dir)
    source = File.join(dir, "share", "cursor-skills", "ai-flow")
    FileUtils.mkdir_p(source)
    File.write(File.join(source, "SKILL.md"), "# skill\n")
    [source, File.join(dir, "skills")]
  end

  test "installs the symlink on first run" do
    Given "a skill source and an empty skills dir"
    dir = Dir.mktmpdir("ai-flow-skill-test-")
    source, skills_dir = build_dirs(dir)
    installer = Dev::Plan::SkillInstaller.new(skill_source: source, skills_dir: skills_dir)

    When "ensuring installation"
    installer.ensure_installed

    Then "the symlink points at the shipped skill"
    File.symlink?(File.join(skills_dir, "ai-flow"))
    File.readlink(File.join(skills_dir, "ai-flow")) == source

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "is idempotent when the symlink is already correct" do
    Given "an already-installed skill"
    dir = Dir.mktmpdir("ai-flow-skill-test-")
    source, skills_dir = build_dirs(dir)
    installer = Dev::Plan::SkillInstaller.new(skill_source: source, skills_dir: skills_dir)
    installer.ensure_installed

    When "ensuring again"
    installer.ensure_installed

    Then "the symlink is unchanged"
    File.readlink(File.join(skills_dir, "ai-flow")) == source

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "re-points a stale symlink (e.g. after a brew upgrade moved the source)" do
    Given "a symlink pointing at an old location"
    dir = Dir.mktmpdir("ai-flow-skill-test-")
    source, skills_dir = build_dirs(dir)
    FileUtils.mkdir_p(skills_dir)
    File.symlink(File.join(dir, "old-location"), File.join(skills_dir, "ai-flow"))
    installer = Dev::Plan::SkillInstaller.new(skill_source: source, skills_dir: skills_dir)

    When "ensuring installation"
    installer.ensure_installed

    Then "the symlink now points at the current source"
    File.readlink(File.join(skills_dir, "ai-flow")) == source

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "leaves a real directory in place rather than clobbering it" do
    Given "a user-owned directory where the symlink would go"
    dir = Dir.mktmpdir("ai-flow-skill-test-")
    source, skills_dir = build_dirs(dir)
    user_dir = File.join(skills_dir, "ai-flow")
    FileUtils.mkdir_p(user_dir)
    File.write(File.join(user_dir, "SKILL.md"), "user's own\n")
    installer = Dev::Plan::SkillInstaller.new(skill_source: source, skills_dir: skills_dir)

    When "ensuring installation"
    installer.ensure_installed

    Then "the directory survives untouched"
    File.directory?(user_dir)
    !File.symlink?(user_dir)
    File.read(File.join(user_dir, "SKILL.md")) == "user's own\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "no-ops when the skill source is missing" do
    Given "an installer over a nonexistent source"
    dir = Dir.mktmpdir("ai-flow-skill-test-")
    skills_dir = File.join(dir, "skills")
    installer = Dev::Plan::SkillInstaller.new(
      skill_source: File.join(dir, "missing"), skills_dir: skills_dir,
    )

    When "ensuring installation"
    installer.ensure_installed

    Then "nothing is created"
    !File.exist?(File.join(skills_dir, "ai-flow"))

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
