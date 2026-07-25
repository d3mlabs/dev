# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/knowledge/cache"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class Dev::Knowledge::CacheTest < Minitest::Test
  # A real git repo playing the knowledge repo: index.md + one skill.
  def build_source_repo(dir)
    source = File.join(dir, "knowledge")
    FileUtils.mkdir_p(File.join(source, "skills", "typed-errors"))
    File.write(File.join(source, "skills", "typed-errors", "SKILL.md"), "# typed errors\n")
    File.write(File.join(source, "index.md"), "## Invariants (always-on)\n\n- [x] a line\n")
    git(source, "init", "-q")
    git(source, "add", ".")
    commit(source, "seed")
    source
  end

  def git(dir, *args)
    system("git", "-C", dir, *args, exception: true)
  end

  def commit(dir, message)
    git(dir, "-c", "user.email=dev@test", "-c", "user.name=dev", "commit", "-qm", message)
  end

  test "refresh clones the repo into the cache dir on first run" do
    Given "a source repo and an empty cache location"
    dir = Dir.mktmpdir("dev-knowledge-cache-test-")
    source = build_source_repo(dir)
    cache = Dev::Knowledge::Cache.new(repo: source, dir: File.join(dir, "cache"))

    When "refreshing"
    cache.refresh

    Then "the cache is present, with the knowledge layout readable"
    cache.present?
    cache.index_file.file?
    (cache.skills_dir / "typed-errors" / "SKILL.md").file?
    !cache.synced_at.nil?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "refresh fast-forwards an existing cache to new upstream content" do
    Given "a cloned cache and a new upstream commit"
    dir = Dir.mktmpdir("dev-knowledge-cache-test-")
    source = build_source_repo(dir)
    cache = Dev::Knowledge::Cache.new(repo: source, dir: File.join(dir, "cache"))
    cache.refresh
    File.write(File.join(source, "index.md"), "## Invariants (always-on)\n\n- [x] a newer line\n")
    git(source, "add", ".")
    commit(source, "update")

    When "refreshing again"
    cache.refresh

    Then "the cache carries the new content"
    cache.index_file.read.include?("a newer line")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "stale? follows the TTL against the last sync time" do
    Given "a freshly cloned cache"
    dir = Dir.mktmpdir("dev-knowledge-cache-test-")
    source = build_source_repo(dir)
    cache = Dev::Knowledge::Cache.new(repo: source, dir: File.join(dir, "cache"))
    cache.refresh

    When "the sync marker ages an hour"
    old = Time.now - 3600
    marker = File.join(dir, "cache", ".git", "HEAD")
    File.utime(old, old, marker)

    Then "staleness follows the TTL"
    cache.stale?(900)
    !cache.stale?(7200)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a never-cloned cache is absent, unsynced, and stale" do
    Given "a cache over a dir that was never cloned"
    dir = Dir.mktmpdir("dev-knowledge-cache-test-")
    cache = Dev::Knowledge::Cache.new(repo: File.join(dir, "nowhere"), dir: File.join(dir, "cache"))

    Expect
    !cache.present?
    cache.synced_at.nil?
    cache.stale?(900)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a failing first clone raises KnowledgeCloneError" do
    Given "a nonexistent source"
    dir = Dir.mktmpdir("dev-knowledge-cache-test-")
    cache = Dev::Knowledge::Cache.new(repo: File.join(dir, "nowhere"), dir: File.join(dir, "cache"))

    When "refreshing"
    cache.refresh

    Then
    raises Dev::Knowledge::Cache::KnowledgeCloneError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a failing pull raises KnowledgeFetchError" do
    Given "a cloned cache whose upstream disappeared"
    dir = Dir.mktmpdir("dev-knowledge-cache-test-")
    source = build_source_repo(dir)
    cache = Dev::Knowledge::Cache.new(repo: source, dir: File.join(dir, "cache"))
    cache.refresh
    FileUtils.rm_rf(source)

    When "refreshing"
    cache.refresh

    Then
    raises Dev::Knowledge::Cache::KnowledgeFetchError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "refresh_async never raises, even when the refresh will fail" do
    Given "a cache whose upstream is gone"
    dir = Dir.mktmpdir("dev-knowledge-cache-test-")
    cache = Dev::Knowledge::Cache.new(repo: File.join(dir, "nowhere"), dir: File.join(dir, "cache"))

    When "kicking a background refresh"
    cache.refresh_async

    Then "the caller is not disturbed (the failure only extends staleness)"
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
