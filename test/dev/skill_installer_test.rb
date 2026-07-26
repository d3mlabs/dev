# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/skill_installer"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class Dev::SkillInstallerTest < Minitest::Test
  def build_skill(dir, *path_parts)
    source = File.join(dir, *path_parts)
    FileUtils.mkdir_p(source)
    File.write(File.join(source, "SKILL.md"), "# skill\n")
    source
  end

  test "install creates the symlink on first run" do
    Given "a skill source and an empty skills dir"
    dir = Dir.mktmpdir("dev-skill-test-")
    source = build_skill(dir, "share", "cursor-skills", "ai-flow")
    skills_dir = File.join(dir, "skills")
    installer = Dev::SkillInstaller.new(skills_dir: skills_dir)

    When "installing the skill"
    installer.install("ai-flow", source)

    Then "the symlink points at the source"
    File.symlink?(File.join(skills_dir, "ai-flow"))
    File.readlink(File.join(skills_dir, "ai-flow")) == source

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install is idempotent when the symlink is already correct" do
    Given "an already-installed skill"
    dir = Dir.mktmpdir("dev-skill-test-")
    source = build_skill(dir, "share", "cursor-skills", "ai-flow")
    skills_dir = File.join(dir, "skills")
    installer = Dev::SkillInstaller.new(skills_dir: skills_dir)
    installer.install("ai-flow", source)

    When "installing again"
    installer.install("ai-flow", source)

    Then "the symlink is unchanged"
    File.readlink(File.join(skills_dir, "ai-flow")) == source

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install re-points a stale symlink (e.g. after a brew upgrade moved the source)" do
    Given "a symlink pointing at an old location"
    dir = Dir.mktmpdir("dev-skill-test-")
    source = build_skill(dir, "share", "cursor-skills", "ai-flow")
    skills_dir = File.join(dir, "skills")
    FileUtils.mkdir_p(skills_dir)
    File.symlink(File.join(dir, "old-location"), File.join(skills_dir, "ai-flow"))
    installer = Dev::SkillInstaller.new(skills_dir: skills_dir)

    When "installing the skill"
    installer.install("ai-flow", source)

    Then "the symlink now points at the current source"
    File.readlink(File.join(skills_dir, "ai-flow")) == source

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install leaves a real directory in place rather than clobbering it" do
    Given "a user-owned directory where the symlink would go"
    dir = Dir.mktmpdir("dev-skill-test-")
    source = build_skill(dir, "share", "cursor-skills", "ai-flow")
    skills_dir = File.join(dir, "skills")
    user_dir = File.join(skills_dir, "ai-flow")
    FileUtils.mkdir_p(user_dir)
    File.write(File.join(user_dir, "SKILL.md"), "user's own\n")
    installer = Dev::SkillInstaller.new(skills_dir: skills_dir)
    old_stderr = $stderr
    $stderr = StringIO.new

    When "installing the skill"
    installer.install("ai-flow", source)

    Then "the directory survives untouched"
    File.directory?(user_dir)
    !File.symlink?(user_dir)
    File.read(File.join(user_dir, "SKILL.md")) == "user's own\n"

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(dir)
  end

  test "install no-ops when the skill source is missing" do
    Given "an installer and a nonexistent source"
    dir = Dir.mktmpdir("dev-skill-test-")
    skills_dir = File.join(dir, "skills")
    installer = Dev::SkillInstaller.new(skills_dir: skills_dir)

    When "installing from the missing source"
    installer.install("ai-flow", File.join(dir, "missing"))

    Then "nothing is created"
    !File.exist?(File.join(skills_dir, "ai-flow"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install warns instead of raising when the skills dir cannot be created" do
    Given "a skills dir under a read-only parent"
    dir = Dir.mktmpdir("dev-skill-test-")
    source = build_skill(dir, "share", "cursor-skills", "ai-flow")
    read_only_parent = File.join(dir, "read-only")
    FileUtils.mkdir_p(read_only_parent)
    FileUtils.chmod(0o555, read_only_parent)
    installer = Dev::SkillInstaller.new(skills_dir: File.join(read_only_parent, "skills"))
    old_stderr = $stderr
    $stderr = StringIO.new

    When "installing the skill"
    installer.install("ai-flow", source)

    Then "the failure is a warning, not an exception"
    $stderr.string.include?("could not install the ai-flow skill symlink")

    Cleanup
    $stderr = old_stderr
    FileUtils.chmod(0o755, read_only_parent)
    FileUtils.rm_rf(dir)
  end

  test "install_all links every skill dir carrying a SKILL.md and skips the rest" do
    Given "a source root with two skills and one non-skill dir"
    dir = Dir.mktmpdir("dev-skill-test-")
    build_skill(dir, "source", "capture-learning")
    build_skill(dir, "source", "typed-errors")
    FileUtils.mkdir_p(File.join(dir, "source", "not-a-skill"))
    skills_dir = File.join(dir, "skills")
    installer = Dev::SkillInstaller.new(skills_dir: skills_dir)

    When "installing all skills"
    installer.install_all(File.join(dir, "source"))

    Then "each skill dir is linked under its own name, the non-skill is not"
    File.readlink(File.join(skills_dir, "capture-learning")) == File.join(dir, "source", "capture-learning")
    File.readlink(File.join(skills_dir, "typed-errors")) == File.join(dir, "source", "typed-errors")
    !File.exist?(File.join(skills_dir, "not-a-skill"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all prefixes link names (the gem link convention)" do
    Given "a gem-style skills dir"
    dir = Dir.mktmpdir("dev-skill-test-")
    build_skill(dir, "gems", "rspock-1.2.0", "skills", "rspock")
    skills_dir = File.join(dir, "skills")
    installer = Dev::SkillInstaller.new(skills_dir: skills_dir)

    When "installing all skills with a prefix"
    installer.install_all(File.join(dir, "gems", "rspock-1.2.0", "skills"), prefix: "gem-rspock--")

    Then "the link carries the prefix"
    File.symlink?(File.join(skills_dir, "gem-rspock--rspock"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all prunes links whose skill disappeared from the source, leaving foreign links" do
    Given "an installed skill later removed from the source, plus a foreign link"
    dir = Dir.mktmpdir("dev-skill-test-")
    source_root = File.join(dir, "source")
    build_skill(dir, "source", "kept")
    removed = build_skill(dir, "source", "removed")
    skills_dir = File.join(dir, "skills")
    installer = Dev::SkillInstaller.new(skills_dir: skills_dir)
    installer.install_all(source_root)
    FileUtils.rm_rf(removed)
    foreign_target = build_skill(dir, "elsewhere", "mine")
    FileUtils.rm_rf(foreign_target) # a broken link, but not under source_root
    File.symlink(foreign_target, File.join(skills_dir, "mine"))

    When "installing all skills again"
    installer.install_all(source_root)

    Then "the vanished skill's link is pruned; the foreign link survives"
    File.symlink?(File.join(skills_dir, "kept"))
    !File.symlink?(File.join(skills_dir, "removed"))
    File.symlink?(File.join(skills_dir, "mine"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all warns instead of raising when pruning cannot read the skills dir" do
    Given "an unreadable skills dir"
    dir = Dir.mktmpdir("dev-skill-test-")
    source_root = File.join(dir, "source")
    FileUtils.mkdir_p(source_root)
    skills_dir = File.join(dir, "skills")
    FileUtils.mkdir_p(skills_dir)
    FileUtils.chmod(0o000, skills_dir)
    installer = Dev::SkillInstaller.new(skills_dir: skills_dir)
    old_stderr = $stderr
    $stderr = StringIO.new

    When "installing all skills"
    installer.install_all(source_root)

    Then "the prune failure is a warning, not an exception"
    $stderr.string.include?("could not prune stale skill symlinks")

    Cleanup
    $stderr = old_stderr
    FileUtils.chmod(0o755, skills_dir)
    FileUtils.rm_rf(dir)
  end

  test "remove deletes a symlink but never a user-owned entry" do
    Given "one skill link and one real directory"
    dir = Dir.mktmpdir("dev-skill-test-")
    source = build_skill(dir, "source", "linked")
    skills_dir = File.join(dir, "skills")
    installer = Dev::SkillInstaller.new(skills_dir: skills_dir)
    installer.install("linked", source)
    user_dir = File.join(skills_dir, "user-owned")
    FileUtils.mkdir_p(user_dir)

    When "removing both names"
    installer.remove("linked")
    installer.remove("user-owned")

    Then "only the symlink is gone"
    !File.symlink?(File.join(skills_dir, "linked"))
    File.directory?(user_dir)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "SHIPPED_SKILLS_DIR points at dev's packaged skills" do
    Expect "the shipped ai-flow skill resolves under it"
    (Dev::SkillInstaller::SHIPPED_SKILLS_DIR / "ai-flow" / "SKILL.md").file?
  end
end
