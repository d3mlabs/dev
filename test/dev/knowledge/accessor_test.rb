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
class Dev::Knowledge::AccessorTest < Minitest::Test
  # A real git source repo plus a fully tmpdir-scoped accessor (nothing
  # touches the real user config, cache, or skills). Returns [accessor, dir
  # pieces we assert on].
  def build_env(dir)
    source = build_source_repo(dir)
    config = File.join(dir, "config.yml")
    File.write(config, "knowledge_repo: #{source}\nknowledge_ttl: 900\n")
    settings = Dev::Settings.new(config_path: config)
    cache = Dev::Knowledge::Cache.new(repo: source, dir: File.join(dir, "cache"))
    installer = Dev::SkillInstaller.new(skills_dir: File.join(dir, "user-skills"))
    synchronizer = Dev::Knowledge::Synchronizer.new(settings: settings, cache: cache, skill_installer: installer)
    project = Pathname(dir) / "repo"
    FileUtils.mkdir_p(project)
    accessor = Dev::Knowledge::Accessor.new(
      project_root: project, settings: settings, cache: cache, synchronizer: synchronizer,
    )
    [accessor, cache, project]
  end

  def build_source_repo(dir)
    source = File.join(dir, "knowledge")
    FileUtils.mkdir_p(File.join(source, "skills", "srp"))
    File.write(File.join(source, "skills", "srp", "SKILL.md"), "# srp\n")
    File.write(File.join(source, "index.md"), "## Invariants (always-on)\n\n- [design/srp] One reason.\n")
    system("git", "-C", source, "init", "-q", exception: true)
    system("git", "-C", source, "add", ".", exception: true)
    system("git", "-C", source, "-c", "user.email=dev@test", "-c", "user.name=dev",
      "commit", "-qm", "seed", exception: true)
    source
  end

  test "knowledge sync clones, distributes, and reports" do
    Given "a configured accessor with no cache yet"
    dir = Dir.mktmpdir("dev-knowledge-acc-test-")
    accessor, cache, project = build_env(dir)
    out = StringIO.new

    When "running dev knowledge sync"
    accessor.run(["sync"], out: out)

    Then "the cache and both artifacts exist, and the sync is reported"
    cache.present?
    File.symlink?(File.join(dir, "user-skills", "srp"))
    (project / ".cursor" / "rules" / "org-invariants.mdc").file?
    out.string.include?("knowledge cache synced")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status reports a missing configuration with instructions" do
    Given "an accessor over empty settings"
    dir = Dir.mktmpdir("dev-knowledge-acc-test-")
    saved_env = ENV.delete("DEV_KNOWLEDGE_REPO")
    accessor = Dev::Knowledge::Accessor.new(
      project_root: dir, settings: Dev::Settings.new(config_path: File.join(dir, "config.yml")),
    )
    out = StringIO.new

    When "running dev knowledge status"
    accessor.run(["status"], out: out)

    Then "the message names the setting and the ENV override"
    out.string.include?("knowledge_repo:")
    out.string.include?("DEV_KNOWLEDGE_REPO")

    Cleanup
    ENV["DEV_KNOWLEDGE_REPO"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "status before the first clone points at dev knowledge sync" do
    Given "a configured accessor with no cache yet"
    dir = Dir.mktmpdir("dev-knowledge-acc-test-")
    accessor, = build_env(dir)
    out = StringIO.new

    When "running dev knowledge status"
    accessor.run(["status"], out: out)

    Then
    out.string.include?("not cloned yet")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status reports freshness against the TTL" do
    Given "a synced cache"
    dir = Dir.mktmpdir("dev-knowledge-acc-test-")
    accessor, cache, = build_env(dir)
    cache.refresh
    fresh_out = StringIO.new
    accessor.run(["status"], out: fresh_out)

    When "the cache ages past the TTL"
    old = Time.now - 3600
    File.utime(old, old, File.join(dir, "cache", ".git", "HEAD"))
    stale_out = StringIO.new
    accessor.run(["status"], out: stale_out)

    Then "fresh before, stale after"
    fresh_out.string.include?("fresh")
    stale_out.string.include?("stale")
    stale_out.string.include?("dev knowledge sync")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an unrecognized invocation is rejected with usage" do
    Given "a configured accessor"
    dir = Dir.mktmpdir("dev-knowledge-acc-test-")
    accessor, = build_env(dir)

    When "running an unknown subcommand"
    accessor.run(["bogus"], out: StringIO.new)

    Then
    raises Dev::Knowledge::Accessor::UsageError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "extra arguments to a subcommand are rejected with usage" do
    Given "a configured accessor"
    dir = Dir.mktmpdir("dev-knowledge-acc-test-")
    accessor, = build_env(dir)

    When "running sync with a stray argument"
    accessor.run(["sync", "extra"], out: StringIO.new)

    Then
    raises Dev::Knowledge::Accessor::UsageError

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
