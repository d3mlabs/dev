# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/learnings"
require "dev/settings"
require "dev/skill_installer"
require "pathname"
require "tmpdir"
require "fileutils"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Learnings::SynchronizerTest < Minitest::Test
  # A real git repo playing the knowledge repo, plus tmpdir-scoped settings,
  # cache, skills dir, and project. Returns the wired synchronizer parts.
  def build_env(dir, refresh_floor: 0)
    source = build_source_repo(dir)
    config = File.join(dir, "config.yml")
    File.write(config, "knowledge_repo: #{source}\n")
    settings = hermetic_settings(dir)
    cache = Dev::Learnings::Cache.new(repo: source, dir: File.join(dir, "cache"), refresh_floor: refresh_floor)
    # The fixture cache lives under the real temp dir; the tmpdir override
    # keeps the installer's ephemeral-source guard out of these tests' way.
    installer = Dev::SkillInstaller.new(skills_dir: File.join(dir, "user-skills"), tmpdir: File.join(dir, "tmp"))
    project = Pathname(dir) / "repo"
    FileUtils.mkdir_p(project)
    synchronizer = Dev::Learnings::Synchronizer.new(settings: settings, cache: cache, skill_installer: installer)
    [synchronizer, cache, project, source]
  end

  def build_source_repo(dir)
    source = File.join(dir, "knowledge")
    FileUtils.mkdir_p(File.join(source, "skills", "typed-errors"))
    File.write(File.join(source, "skills", "typed-errors", "SKILL.md"), "# typed errors\n")
    File.write(File.join(source, "index.md"), "## Invariants (always-on)\n\n- [design/srp] One reason to change.\n")
    system("git", "-C", source, "init", "-q", exception: true)
    commit_all(source, "seed")
    source
  end

  def commit_all(source, message)
    system("git", "-C", source, "add", ".", exception: true)
    system("git", "-C", source, "-c", "user.email=dev@test", "-c", "user.name=dev",
      "commit", "-qm", message, exception: true)
  end

  # Settings with both file layers pinned inside the temp dir — the
  # machine's real system config (installed by a deployment formula) must
  # never leak a knowledge_repo into these tests.
  def hermetic_settings(dir)
    Dev::Settings.new(
      config_path: File.join(dir, "config.yml"),
      system_config_path: File.join(dir, "system-config.yml"),
    )
  end

  test "sync! refreshes the cache, links org skills, renders machine-side, and links the project" do
    Given "a configured synchronizer with an empty cache"
    dir = Dir.mktmpdir("dev-learnings-sync-test-")
    synchronizer, cache, project, = build_env(dir)

    When "forcing a sync into the project"
    synchronizer.sync!(project_root: project)

    Then "cache cloned, skill linked user-globally, invariants rendered once beside the cache, project symlinked"
    cache.present?
    File.symlink?(File.join(dir, "user-skills", "typed-errors"))
    synchronizer.rendered_invariants_file.file?
    rules = project / ".cursor" / "rules" / "org-invariants.mdc"
    rules.symlink?
    rules.readlink == synchronizer.rendered_invariants_file
    rules.read.include?("[design/srp]")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the passive hook pulls inline before distributing — it never renders content it found stale" do
    Given "a cloned cache that upstream has since moved past"
    dir = Dir.mktmpdir("dev-learnings-sync-test-")
    synchronizer, cache, project, source = build_env(dir)
    cache.refresh
    File.write(File.join(source, "index.md"), "## Invariants (always-on)\n\n- [design/newer] A fresh invariant.\n")
    commit_all(source, "update")

    When "the passive hook runs"
    synchronizer.sync(project_root: project)

    Then "the project already resolves to the fresh upstream content"
    (project / ".cursor" / "rules" / "org-invariants.mdc").read.include?("[design/newer]")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the passive hook inside the courtesy floor serves the cache without pulling" do
    Given "a just-refreshed cache and a newer upstream commit"
    dir = Dir.mktmpdir("dev-learnings-sync-test-")
    synchronizer, cache, project, source = build_env(dir, refresh_floor: 3600)
    cache.refresh
    File.write(File.join(source, "index.md"), "## Invariants (always-on)\n\n- [design/newer] A fresh invariant.\n")
    commit_all(source, "update")

    When "the passive hook runs inside the floor"
    synchronizer.sync(project_root: project)

    Then "distribution served the current cache (no pull)"
    rules = project / ".cursor" / "rules" / "org-invariants.mdc"
    rules.read.include?("[design/srp]")
    !rules.read.include?("[design/newer]")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a sync without a project does the machine-global parts and skips the project link" do
    Given "a configured synchronizer"
    dir = Dir.mktmpdir("dev-learnings-sync-test-")
    synchronizer, cache, project, = build_env(dir)

    When "syncing with no project root"
    synchronizer.sync!

    Then "cache, skills, and the machine-side render exist; no project was touched"
    cache.present?
    File.symlink?(File.join(dir, "user-skills", "typed-errors"))
    synchronizer.rendered_invariants_file.file?
    !(project / ".cursor").exist?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test ".for on a configured machine builds the real synchronizer" do
    Given "settings with a knowledge repo"
    dir = Dir.mktmpdir("dev-learnings-sync-test-")
    config = File.join(dir, "config.yml")
    File.write(config, "knowledge_repo: d3mlabs/knowledge\n")
    settings = hermetic_settings(dir)

    When "constructing through the factory"
    synchronizer = Dev::Learnings::Synchronizer.for(settings: settings)

    Then "the real synchronizer comes back, cache and all"
    synchronizer.is_a?(Dev::Learnings::Synchronizer)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test ".for on an unconfigured machine hands out the null synchronizer, whose passive hook is a silent no-op" do
    Given "settings without a knowledge repo"
    dir = Dir.mktmpdir("dev-learnings-sync-test-")
    saved_env = ENV.delete("DEV_KNOWLEDGE_REPO")
    settings = hermetic_settings(dir)
    installer = Dev::SkillInstaller.new(skills_dir: File.join(dir, "user-skills"), tmpdir: File.join(dir, "tmp"))
    synchronizer = Dev::Learnings::Synchronizer.for(settings: settings, skill_installer: installer)
    project = Pathname(dir) / "repo"
    FileUtils.mkdir_p(project)

    When "the passive hook runs"
    synchronizer.sync(project_root: project)

    Then "no org sync happened, silently"
    synchronizer.is_a?(Dev::Learnings::UnconfiguredSynchronizer)
    !File.exist?(File.join(dir, "user-skills"))
    !(project / ".cursor").exist?

    Cleanup
    ENV["DEV_KNOWLEDGE_REPO"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "sync! on an unconfigured machine raises with configuration instructions" do
    Given "the null synchronizer of an unconfigured machine"
    dir = Dir.mktmpdir("dev-learnings-sync-test-")
    saved_env = ENV.delete("DEV_KNOWLEDGE_REPO")
    settings = hermetic_settings(dir)
    synchronizer = Dev::Learnings::Synchronizer.for(settings: settings)

    When "forcing a sync"
    synchronizer.sync!

    Then
    raises Dev::Learnings::Synchronizer::KnowledgeRepoNotConfiguredError

    Cleanup
    ENV["DEV_KNOWLEDGE_REPO"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "the passive hook never raises — a broken sync only warns" do
    Given "a cache that blows up on the bounded refresh"
    dir = Dir.mktmpdir("dev-learnings-sync-test-")
    synchronizer, cache, project, = build_env(dir)
    cache.stubs(:refresh_bounded).raises(RuntimeError, "boom")
    old_stderr = $stderr
    $stderr = StringIO.new

    When "the passive hook runs"
    synchronizer.sync(project_root: project)

    Then "the failure is a warning, not an exception"
    $stderr.string.include?("org learnings sync failed")

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(dir)
  end
end
