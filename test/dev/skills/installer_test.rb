# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/skills/installer"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class Dev::Skills::InstallerTest < Minitest::Test
  def build_skill(dir, *path_parts)
    source = File.join(dir, *path_parts)
    FileUtils.mkdir_p(source)
    File.write(File.join(source, "SKILL.md"), "# skill\n")
    source
  end

  # Installer under test. The real Dir.tmpdir contains these tests' own
  # fixture trees, so every installer gets a tmpdir override pointing inside
  # the fixture dir — sources built by build_skill read as durable, and a
  # test opts into ephemerality by building under `<dir>/tmp`.
  def build_installer(dir, skills_dir:)
    Dev::Skills::Installer.new(skills_dir: skills_dir, tmpdir: File.join(dir, "tmp"))
  end

  test "install creates the symlink on first run" do
    Given "a skill source and an empty skills dir"
    dir = Dir.mktmpdir("dev-skill-test-")
    source = build_skill(dir, "share", "cursor-skills", "ai-flow")
    skills_dir = File.join(dir, "skills")
    installer = build_installer(dir, skills_dir: skills_dir)

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
    installer = build_installer(dir, skills_dir: skills_dir)
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
    installer = build_installer(dir, skills_dir: skills_dir)

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
    installer = build_installer(dir, skills_dir: skills_dir)
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
    installer = build_installer(dir, skills_dir: skills_dir)

    When "installing from the missing source"
    installer.install("ai-flow", File.join(dir, "missing"))

    Then "nothing is created"
    !File.exist?(File.join(skills_dir, "ai-flow"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install refuses a source under the temp dir and warns" do
    Given "a skill source living under the ephemeral temp dir (e.g. a dev checkout in a build workspace)"
    dir = Dir.mktmpdir("dev-skill-test-")
    source = build_skill(dir, "tmp", "clone", "share", "cursor-skills", "ai-flow")
    skills_dir = File.join(dir, "skills")
    installer = build_installer(dir, skills_dir: skills_dir)
    old_stderr = $stderr
    $stderr = StringIO.new

    When "installing the skill"
    installer.install("ai-flow", source)

    Then "no link is minted and the skip is warned"
    !File.exist?(File.join(skills_dir, "ai-flow"))
    $stderr.string.include?("not linking ai-flow")

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(dir)
  end

  test "install refuses an ephemeral source even when it would replace a dangling link" do
    Given "a link already dangling, and a refresh source under the temp dir"
    dir = Dir.mktmpdir("dev-skill-test-")
    source = build_skill(dir, "tmp", "clone", "share", "cursor-skills", "ai-flow")
    skills_dir = File.join(dir, "skills")
    FileUtils.mkdir_p(skills_dir)
    File.symlink(File.join(dir, "gone"), File.join(skills_dir, "ai-flow"))
    installer = build_installer(dir, skills_dir: skills_dir)
    old_stderr = $stderr
    $stderr = StringIO.new

    When "installing the skill"
    installer.install("ai-flow", source)

    Then "the existing link is left alone rather than re-pointed at purgeable state"
    File.readlink(File.join(skills_dir, "ai-flow")) == File.join(dir, "gone")

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(dir)
  end

  test "temp dir containment sees through symlinked temp roots (macOS /var vs /private/var)" do
    Given "a tmpdir override that is a symlink to the dir the source lives under"
    dir = Dir.mktmpdir("dev-skill-test-")
    source = build_skill(dir, "tmp", "share", "cursor-skills", "ai-flow")
    tmp_alias = File.join(dir, "tmp-alias")
    File.symlink(File.join(dir, "tmp"), tmp_alias)
    skills_dir = File.join(dir, "skills")
    installer = Dev::Skills::Installer.new(skills_dir: skills_dir, tmpdir: tmp_alias)
    old_stderr = $stderr
    $stderr = StringIO.new

    When "installing the skill"
    installer.install("ai-flow", source)

    Then "the path is recognized as ephemeral and never links"
    !File.exist?(File.join(skills_dir, "ai-flow"))

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(dir)
  end

  test "install warns instead of raising when the skills dir cannot be created" do
    Given "a skills dir under a read-only parent"
    dir = Dir.mktmpdir("dev-skill-test-")
    source = build_skill(dir, "share", "cursor-skills", "ai-flow")
    read_only_parent = File.join(dir, "read-only")
    FileUtils.mkdir_p(read_only_parent)
    FileUtils.chmod(0o555, read_only_parent)
    installer = build_installer(dir, skills_dir: File.join(read_only_parent, "skills"))
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

  test "remove deletes a symlink but never a user-owned entry" do
    Given "one skill link and one real directory"
    dir = Dir.mktmpdir("dev-skill-test-")
    source = build_skill(dir, "source", "linked")
    skills_dir = File.join(dir, "skills")
    installer = build_installer(dir, skills_dir: skills_dir)
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

  test "install creates the parent dirs of a nested link name" do
    Given "a nested link name under an empty skills dir"
    dir = Dir.mktmpdir("dev-skill-test-")
    source = build_skill(dir, "gems", "rspock-3.0.0", "skills", "rspock")
    skills_dir = File.join(dir, "skills")
    installer = build_installer(dir, skills_dir: skills_dir)

    When "installing"
    installer.install("gem/rspock/rspock", source)

    Then "the link sits under its package dir"
    File.readlink(File.join(skills_dir, "gem", "rspock", "rspock")) == source

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "remove of a nested link also removes the dirs it empties, up to but not including the skills dir" do
    Given "two skills of one package and one of another"
    dir = Dir.mktmpdir("dev-skill-test-")
    skills_dir = File.join(dir, "skills")
    installer = build_installer(dir, skills_dir: skills_dir)
    installer.install("gem/a/one", build_skill(dir, "gems", "a", "one"))
    installer.install("gem/a/two", build_skill(dir, "gems", "a", "two"))
    installer.install("gem/b/only", build_skill(dir, "gems", "b", "only"))

    When "removing one of a's and b's only, observing a's dir in between, then a's last"
    installer.remove("gem/a/one")
    installer.remove("gem/b/only")
    a_dir_stood = File.directory?(File.join(skills_dir, "gem", "a")) && File.symlink?(File.join(skills_dir, "gem", "a", "two"))
    b_dir_gone = !File.exist?(File.join(skills_dir, "gem", "b"))
    gem_dir_stood = File.directory?(File.join(skills_dir, "gem"))
    installer.remove("gem/a/two")

    Then "a's dir stayed while it had two, b's went with its only, gem/ stayed until a's last; the skills dir remains"
    a_dir_stood
    b_dir_gone
    gem_dir_stood
    !File.exist?(File.join(skills_dir, "gem"))
    File.directory?(skills_dir)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "remove stops climbing at a parent dir that is not empty" do
    Given "a nested link beside a user file in its package dir"
    dir = Dir.mktmpdir("dev-skill-test-")
    skills_dir = File.join(dir, "skills")
    installer = build_installer(dir, skills_dir: skills_dir)
    installer.install("gem/a/one", build_skill(dir, "gems", "a", "one"))
    File.write(File.join(skills_dir, "gem", "a", "NOTES"), "mine\n")

    When "removing the link"
    installer.remove("gem/a/one")

    Then "the package dir and the user file stand"
    File.file?(File.join(skills_dir, "gem", "a", "NOTES"))

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
