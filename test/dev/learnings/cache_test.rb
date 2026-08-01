# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/learnings/cache"
require "tmpdir"
require "fileutils"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Learnings::CacheTest < Minitest::Test
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

  def commit_index_update(source, line)
    File.write(File.join(source, "index.md"), "## Invariants (always-on)\n\n- [x] #{line}\n")
    git(source, "add", ".")
    commit(source, "update")
  end

  test "refresh clones the repo into the cache dir on first run" do
    Given "a source repo and an empty cache location"
    dir = Dir.mktmpdir("dev-learnings-cache-test-")
    source = build_source_repo(dir)
    cache = Dev::Learnings::Cache.new(repo: source, dir: File.join(dir, "cache"))

    When "refreshing"
    cache.refresh

    Then "the cache is present, with the knowledge repo layout readable"
    cache.present?
    cache.index_file.file?
    (cache.skills_dir / "typed-errors" / "SKILL.md").file?
    !cache.synced_at.nil?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "refresh fast-forwards an existing cache to new upstream content" do
    Given "a cloned cache and a new upstream commit"
    dir = Dir.mktmpdir("dev-learnings-cache-test-")
    source = build_source_repo(dir)
    cache = Dev::Learnings::Cache.new(repo: source, dir: File.join(dir, "cache"))
    cache.refresh
    commit_index_update(source, "a newer line")

    When "refreshing again"
    cache.refresh

    Then "the cache carries the new content"
    cache.index_file.read.include?("a newer line")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "refresh_bounded pulls new upstream content inline" do
    Given "a cloned cache past the courtesy floor, and a new upstream commit"
    dir = Dir.mktmpdir("dev-learnings-cache-test-")
    source = build_source_repo(dir)
    cache = Dev::Learnings::Cache.new(repo: source, dir: File.join(dir, "cache"), refresh_floor: 0)
    cache.refresh
    commit_index_update(source, "a newer line")

    When "a bounded refresh runs"
    cache.refresh_bounded

    Then "the cache already carries the new content — the caller distributes it"
    cache.index_file.read.include?("a newer line")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "refresh_bounded within the courtesy floor is a no-op" do
    Given "a just-refreshed cache and a new upstream commit"
    dir = Dir.mktmpdir("dev-learnings-cache-test-")
    source = build_source_repo(dir)
    cache = Dev::Learnings::Cache.new(repo: source, dir: File.join(dir, "cache"), refresh_floor: 3600)
    cache.refresh
    commit_index_update(source, "a newer line")

    When "a bounded refresh runs inside the floor"
    cache.refresh_bounded

    Then "no pull happened — the cache still serves the previous content"
    !cache.index_file.read.include?("a newer line")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "refresh_bounded detaches a pull slower than the timeout and serves the cache" do
    Given "a cloned cache whose git hangs (fake git on PATH), and a tight timeout"
    dir = Dir.mktmpdir("dev-learnings-cache-test-")
    source = build_source_repo(dir)
    cache = Dev::Learnings::Cache.new(
      repo: source, dir: File.join(dir, "cache"), refresh_floor: 0, refresh_timeout: 0.2,
    )
    cache.refresh
    bin = File.join(dir, "bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "git"), "#!/bin/sh\nsleep 30\n")
    FileUtils.chmod(0o755, File.join(bin, "git"))
    original_path = ENV.fetch("PATH")
    ENV["PATH"] = "#{bin}:#{original_path}"

    When "a bounded refresh runs against the hanging git"
    started = Time.now
    cache.refresh_bounded
    elapsed = Time.now - started

    Then "it returned around the timeout, not the pull's 30s, and the cache is intact"
    elapsed < 5
    cache.index_file.file?

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(dir)
  end

  test "refresh_bounded falls back silently when the pull fails (offline)" do
    Given "a cloned cache whose upstream disappeared"
    dir = Dir.mktmpdir("dev-learnings-cache-test-")
    source = build_source_repo(dir)
    cache = Dev::Learnings::Cache.new(repo: source, dir: File.join(dir, "cache"), refresh_floor: 0)
    cache.refresh
    FileUtils.rm_rf(source)

    When "a bounded refresh runs"
    cache.refresh_bounded

    Then "no exception — the current cache is served as-is"
    cache.present?
    cache.index_file.file?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a never-cloned cache is absent and unsynced" do
    Given "a cache over a dir that was never cloned"
    dir = Dir.mktmpdir("dev-learnings-cache-test-")
    cache = Dev::Learnings::Cache.new(repo: File.join(dir, "nowhere"), dir: File.join(dir, "cache"))

    Expect
    !cache.present?
    cache.synced_at.nil?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a failing first clone raises KnowledgeCloneError" do
    Given "a nonexistent source"
    dir = Dir.mktmpdir("dev-learnings-cache-test-")
    cache = Dev::Learnings::Cache.new(repo: File.join(dir, "nowhere"), dir: File.join(dir, "cache"))

    When "refreshing"
    cache.refresh

    Then
    raises Dev::Learnings::Cache::KnowledgeCloneError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a failing pull raises KnowledgeFetchError" do
    Given "a cloned cache whose upstream disappeared"
    dir = Dir.mktmpdir("dev-learnings-cache-test-")
    source = build_source_repo(dir)
    cache = Dev::Learnings::Cache.new(repo: source, dir: File.join(dir, "cache"))
    cache.refresh
    FileUtils.rm_rf(source)

    When "refreshing"
    cache.refresh

    Then
    raises Dev::Learnings::Cache::KnowledgeFetchError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an owner/repo source clones through gh (riding the user's gh auth)" do
    Given "a fake gh on PATH that records its invocation"
    dir = Dir.mktmpdir("dev-learnings-cache-test-")
    bin = File.join(dir, "bin")
    FileUtils.mkdir_p(bin)
    record = File.join(dir, "gh-args.txt")
    File.write(File.join(bin, "gh"), "#!/bin/sh\necho \"$@\" > \"#{record}\"\n")
    FileUtils.chmod(0o755, File.join(bin, "gh"))
    original_path = ENV.fetch("PATH")
    ENV["PATH"] = "#{bin}:#{original_path}"
    cache = Dev::Learnings::Cache.new(repo: "d3mlabs/knowledge", dir: File.join(dir, "cache"))

    When "refreshing on first run"
    cache.refresh

    Then "the clone went through gh repo clone"
    File.read(record).start_with?("repo clone d3mlabs/knowledge")

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(dir)
  end

  test "refresh_bounded warns instead of raising when the cache location cannot be created" do
    Given "a cache location under a read-only parent"
    dir = Dir.mktmpdir("dev-learnings-cache-test-")
    read_only_parent = File.join(dir, "read-only")
    FileUtils.mkdir_p(read_only_parent)
    FileUtils.chmod(0o555, read_only_parent)
    cache = Dev::Learnings::Cache.new(repo: "d3mlabs/knowledge", dir: File.join(read_only_parent, "sub", "cache"))
    old_stderr = $stderr
    $stderr = StringIO.new

    When "a bounded refresh runs"
    cache.refresh_bounded

    Then "the failure is a warning, not an exception"
    $stderr.string.include?("could not start the knowledge repo cache refresh")

    Cleanup
    $stderr = old_stderr
    FileUtils.chmod(0o755, read_only_parent)
    FileUtils.rm_rf(dir)
  end
end
