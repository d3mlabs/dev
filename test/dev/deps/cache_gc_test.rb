# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/cache_gc"
require "dev/deps/lockfile"
require "dev/deps/dependency"
require "set"
require "tmpdir"

# CacheGc with the docker boundary replaced by a fixed in-use set, so the
# version-dir retention logic runs for real against the filesystem with no
# docker dependency.
class FixtureCacheGc < Dev::Deps::CacheGc
  def initialize(in_use: [], **kwargs)
    super(**kwargs)
    @in_use_fixture = Set.new(in_use)
  end

  private

  def running_mount_sources = @in_use_fixture
end unless defined?(FixtureCacheGc)

transform!(RSpock::AST::Transformation)
class Dev::Deps::CacheGcTest < Minitest::Test
  # Create version subdirs under base with strictly increasing mtimes, so the
  # last name listed is the newest.
  def seed_versions(base, *versions)
    FileUtils.mkdir_p(base)
    versions.each_with_index do |version, index|
      dir = File.join(base, version)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, ".dev-gh-release"), version)
      stamp = Time.now + index
      File.utime(stamp, stamp, dir)
    end
  end

  def lock_engine(lock_dir, base, version:)
    lockfile = Dev::Deps::Lockfile.new(dir: lock_dir)
    lockfile.lock([
      Dev::Deps::Dependency.new(
        name: "UnrealEngine", integration: :gh, group: :build,
        version: version, hash: nil, metadata: { "install_dir" => base },
      ),
    ])
    lockfile
  end

  test "gc keeps the locked version plus the newest others up to keep, removing the rest" do
    Given "four versions where the locked one is not the newest"
    dir = Dir.mktmpdir("dev-cache-gc-test-")
    base = File.join(dir, "engines", "unreal-engine-css")
    seed_versions(base, "a", "b", "c", "d") # d newest
    lockfile = lock_engine(dir, base, version: "c")
    gc = FixtureCacheGc.new(lockfile: lockfile, out: StringIO.new)

    When "collecting with keep: 2"
    gc.gc(keep: 2)

    Then "the locked version (c) and the newest (d) survive; a and b are reclaimed"
    Dir.children(base).sort == ["c", "d"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "gc never removes a version mounted by a running container, even if unlocked and old" do
    Given "an old unlocked version that a live container has mounted"
    dir = Dir.mktmpdir("dev-cache-gc-test-")
    base = File.join(dir, "engines", "unreal-engine-css")
    seed_versions(base, "a", "b", "c") # c newest
    lockfile = lock_engine(dir, base, version: "c")
    gc = FixtureCacheGc.new(lockfile: lockfile, out: StringIO.new, in_use: [File.join(base, "a")])

    When "collecting with a tight keep: 1"
    gc.gc(keep: 1)

    Then "the in-use version (a) and the locked version (c) survive; b is reclaimed"
    Dir.children(base).sort == ["a", "c"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "gc removes orphan staging dirs left by a killed install" do
    Given "a published version and an orphan staging dir"
    dir = Dir.mktmpdir("dev-cache-gc-test-")
    base = File.join(dir, "engines", "unreal-engine-css")
    seed_versions(base, "c")
    FileUtils.mkdir_p(File.join(base, ".staging-999-deadbeef"))
    lockfile = lock_engine(dir, base, version: "c")
    gc = FixtureCacheGc.new(lockfile: lockfile, out: StringIO.new)

    When "collecting"
    gc.gc(keep: 2)

    Then "the orphan staging is gone and the version remains"
    Dir.children(base).sort == ["c"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "gc keeps the locked version even when it is the oldest and keep is exceeded" do
    Given "the locked version is the oldest of several"
    dir = Dir.mktmpdir("dev-cache-gc-test-")
    base = File.join(dir, "engines", "unreal-engine-css")
    seed_versions(base, "old", "mid", "new") # locked = old (oldest)
    lockfile = lock_engine(dir, base, version: "old")
    gc = FixtureCacheGc.new(lockfile: lockfile, out: StringIO.new)

    When "collecting with keep: 2"
    gc.gc(keep: 2)

    Then "the locked oldest survives alongside the single newest; mid is reclaimed"
    Dir.children(base).sort == ["new", "old"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "running_mount_sources collects every running container's mount sources" do
    Given "a gc whose docker capture reports two containers with mounts"
    dir = Dir.mktmpdir("dev-cache-gc-test-")
    gc = Dev::Deps::CacheGc.new(lockfile: Dev::Deps::Lockfile.new(dir: dir), out: StringIO.new)
    gc.stubs(:capture).with(["docker", "ps", "-q"]).returns("abc\ndef\n")
    gc.stubs(:capture)
      .with(["docker", "inspect", "--format", "{{range .Mounts}}{{.Source}}\n{{end}}", "abc", "def"])
      .returns("/mnt/engine\n\n/mnt/cache\n")

    When "collecting mount sources"
    sources = gc.send(:running_mount_sources)

    Then "both sources are present, blank lines dropped"
    sources == Set.new(["/mnt/engine", "/mnt/cache"])

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "gc_docker leaves non-content tags and in-use images alone" do
    Given "a gc whose docker capture reports only a live tag and a plain tag"
    dir = Dir.mktmpdir("dev-cache-gc-test-")
    gc = Dev::Deps::CacheGc.new(lockfile: Dev::Deps::Lockfile.new(dir: dir), out: StringIO.new)
    gc.stubs(:capture)
      .with(["docker", "images", "repo/img", "--format", "{{.Repository}}:{{.Tag}}"])
      .returns("repo/img:latest\nrepo/img:content-abc\n")
    gc.stubs(:capture).with(["docker", "ps", "--format", "{{.Image}}"]).returns("repo/img:content-abc\n")

    When "pruning content tags"
    gc.send(:gc_docker, image_ref: "repo/img", live_tag: nil)

    Then "nothing is removed: latest isn't a content tag, and the content tag is in use"
    true # reaching here without a docker rmi spawn is the assertion (none is stubbed)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "capture returns stdout on success and empty string on failure or a missing binary" do
    Given "a gc"
    dir = Dir.mktmpdir("dev-cache-gc-test-")
    gc = Dev::Deps::CacheGc.new(lockfile: Dev::Deps::Lockfile.new(dir: dir), out: StringIO.new)

    Expect "real subprocess results ride through; failures collapse to empty"
    gc.send(:capture, ["sh", "-c", "echo hi"]) == "hi\n"
    gc.send(:capture, ["sh", "-c", "exit 1"]) == ""
    gc.send(:capture, ["dev-test-missing-binary-xyz"]) == ""

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
