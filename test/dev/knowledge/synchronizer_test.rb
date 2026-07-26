# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/knowledge"
require "dev/settings"
require "dev/skill_installer"
require "pathname"
require "tmpdir"
require "fileutils"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Knowledge::SynchronizerTest < Minitest::Test
  # A real git repo playing the knowledge repo, plus tmpdir-scoped settings,
  # cache, skills dir, and project. Returns the wired synchronizer parts.
  def build_env(dir)
    source = build_source_repo(dir)
    config = File.join(dir, "config.yml")
    File.write(config, "knowledge_repo: #{source}\n")
    settings = Dev::Settings.new(config_path: config)
    cache = Dev::Knowledge::Cache.new(repo: source, dir: File.join(dir, "cache"))
    installer = Dev::SkillInstaller.new(skills_dir: File.join(dir, "user-skills"))
    project = Pathname(dir) / "repo"
    FileUtils.mkdir_p(project)
    synchronizer = Dev::Knowledge::Synchronizer.new(settings: settings, cache: cache, skill_installer: installer)
    [synchronizer, cache, project]
  end

  def build_source_repo(dir)
    source = File.join(dir, "knowledge")
    FileUtils.mkdir_p(File.join(source, "skills", "typed-errors"))
    File.write(File.join(source, "skills", "typed-errors", "SKILL.md"), "# typed errors\n")
    File.write(File.join(source, "index.md"), "## Invariants (always-on)\n\n- [design/srp] One reason to change.\n")
    system("git", "-C", source, "init", "-q", exception: true)
    system("git", "-C", source, "add", ".", exception: true)
    system("git", "-C", source, "-c", "user.email=dev@test", "-c", "user.name=dev",
      "commit", "-qm", "seed", exception: true)
    source
  end

  test "sync! refreshes the cache, links org skills, and renders the invariants rule" do
    Given "a configured synchronizer with an empty cache"
    dir = Dir.mktmpdir("dev-knowledge-sync-test-")
    synchronizer, cache, project = build_env(dir)

    When "forcing a sync into the project"
    synchronizer.sync!(project_root: project)

    Then "cache cloned, skill linked user-globally, invariants rendered project-side"
    cache.present?
    File.symlink?(File.join(dir, "user-skills", "typed-errors"))
    (project / ".cursor" / "rules" / "org-invariants.mdc").read.include?("[design/srp]")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "sync distributes from the current cache and only refreshes past the TTL" do
    Given "a fresh cache (just synced)"
    dir = Dir.mktmpdir("dev-knowledge-sync-test-")
    synchronizer, cache, project = build_env(dir)
    cache.refresh
    cache.expects(:refresh_async).never

    When "the passive hook runs"
    synchronizer.sync(project_root: project)

    Then "no background refresh was kicked, but the artifacts are distributed"
    File.symlink?(File.join(dir, "user-skills", "typed-errors"))
    (project / ".cursor" / "rules" / "org-invariants.mdc").file?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "sync kicks an async refresh once the TTL lapsed" do
    Given "a cache older than the TTL"
    dir = Dir.mktmpdir("dev-knowledge-sync-test-")
    synchronizer, cache, project = build_env(dir)
    cache.refresh
    old = Time.now - 3600
    File.utime(old, old, File.join(dir, "cache", ".git", "HEAD"))
    cache.expects(:refresh_async).once

    When "the passive hook runs"
    synchronizer.sync(project_root: project)

    Then "the refresh went to the background (distribution still served the cache)"
    (project / ".cursor" / "rules" / "org-invariants.mdc").file?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an unconfigured machine has no org sync" do
    Given "settings without a knowledge repo"
    dir = Dir.mktmpdir("dev-knowledge-sync-test-")
    saved_env = ENV.delete("DEV_KNOWLEDGE_REPO")
    settings = Dev::Settings.new(config_path: File.join(dir, "config.yml"))
    installer = Dev::SkillInstaller.new(skills_dir: File.join(dir, "user-skills"))
    synchronizer = Dev::Knowledge::Synchronizer.new(settings: settings, skill_installer: installer)
    project = Pathname(dir) / "repo"
    FileUtils.mkdir_p(project)

    When "the passive hook runs"
    synchronizer.sync(project_root: project)

    Then "it is a silent no-op"
    !synchronizer.configured?
    !File.exist?(File.join(dir, "user-skills"))
    !(project / ".cursor").exist?

    Cleanup
    ENV["DEV_KNOWLEDGE_REPO"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "sync! on an unconfigured machine raises with configuration instructions" do
    Given "settings without a knowledge repo"
    dir = Dir.mktmpdir("dev-knowledge-sync-test-")
    saved_env = ENV.delete("DEV_KNOWLEDGE_REPO")
    settings = Dev::Settings.new(config_path: File.join(dir, "config.yml"))
    synchronizer = Dev::Knowledge::Synchronizer.new(settings: settings)

    When "forcing a sync"
    synchronizer.sync!

    Then
    raises Dev::Knowledge::Synchronizer::KnowledgeRepoNotConfiguredError

    Cleanup
    ENV["DEV_KNOWLEDGE_REPO"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "the passive hook never raises — a broken sync only warns" do
    Given "a cache that blows up on the staleness check"
    dir = Dir.mktmpdir("dev-knowledge-sync-test-")
    synchronizer, cache, project = build_env(dir)
    cache.stubs(:stale?).raises(RuntimeError, "boom")
    old_stderr = $stderr
    $stderr = StringIO.new

    When "the passive hook runs"
    synchronizer.sync(project_root: project)

    Then "the failure is a warning, not an exception"
    $stderr.string.include?("org knowledge sync failed")

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(dir)
  end
end
