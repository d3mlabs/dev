# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/cache_gc"
require "dev/prefix_volumes"
require "dev/deps/lockfile"
require "dev/deps/dependency"
require "dev/deps/local_store"
require "dev/environment_image"
require "support/fake_container_engine"
require "set"
require "tmpdir"

# CacheGc with the docker boundary replaced by a fixed in-use set, so the
# version-dir retention logic runs for real against the filesystem with no
# docker dependency.
class FixtureCacheGc < Dev::Deps::CacheGc
  def initialize(in_use: [], **kwargs)
    super(engine: FakeContainerEngine.new, **kwargs)
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

  ENGINE_REPO = "d3mlabs/unreal-engine"

  # Lock a gh engine; the store places it at <data root>/gh/<repo>/<version>.
  def lock_engine(lock_dir, version:, name: "UnrealEngine")
    lockfile = Dev::Deps::Lockfile.new(dir: lock_dir)
    lockfile.lock([
      Dev::Deps::Dependency.new(
        name: name, integration: :gh, group: :build,
        version: version, hash: nil, metadata: { "repo" => ENGINE_REPO },
      ),
    ])
    lockfile
  end

  # The base the store derives for ENGINE_REPO under data root dir.
  def engine_base(dir) = File.join(dir, "gh", "d3mlabs", "unreal-engine")

  def build_gc(dir, lockfile, **opts)
    FixtureCacheGc.new(lockfile: lockfile, store: Dev::Deps::LocalStore.new(data_root: dir), **opts)
  end

  test "gc keeps the locked version plus the newest others up to keep, removing the rest" do
    Given "four versions where the locked one is not the newest"
    dir = Dir.mktmpdir("dev-cache-gc-test-")
    base = engine_base(dir)
    seed_versions(base, "a", "b", "c", "d") # d newest
    lockfile = lock_engine(dir, version: "c")
    gc = build_gc(dir, lockfile, out: StringIO.new)

    When "collecting with keep: 2"
    gc.gc(keep: 2)

    Then "the locked version (c) and the newest (d) survive; a and b are reclaimed"
    Dir.children(base).sort == ["c", "d"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "gc sees one base for one tree however the lock names it" do
    Given "two locked names for the same repo at two versions, a third version on disk"
    dir = Dir.mktmpdir("dev-cache-gc-test-")
    base = engine_base(dir)
    seed_versions(base, "a", "b", "c") # c newest
    lockfile = Dev::Deps::Lockfile.new(dir: dir)
    lockfile.lock([
      Dev::Deps::Dependency.new(name: "UnrealEngine", integration: :gh, group: :build,
        version: "a", hash: nil, metadata: { "repo" => ENGINE_REPO }),
      Dev::Deps::Dependency.new(name: "UnrealEngineToo", integration: :gh, group: :build,
        version: "b", hash: nil, metadata: { "repo" => ENGINE_REPO }),
    ])
    gc = build_gc(dir, lockfile, out: StringIO.new)

    When "collecting with keep: 1"
    gc.gc(keep: 1)

    Then "both locked versions survive under the one base; only the unlocked newest goes"
    Dir.children(base).sort == ["a", "b"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "gc never removes a version mounted by a running container, even if unlocked and old" do
    Given "an old unlocked version that a live container has mounted"
    dir = Dir.mktmpdir("dev-cache-gc-test-")
    base = engine_base(dir)
    seed_versions(base, "a", "b", "c") # c newest
    lockfile = lock_engine(dir, version: "c")
    gc = build_gc(dir, lockfile, out: StringIO.new, in_use: [File.join(base, "a")])

    When "collecting with a tight keep: 1"
    gc.gc(keep: 1)

    Then "the in-use version (a) and the locked version (c) survive; b is reclaimed"
    Dir.children(base).sort == ["a", "c"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "gc leaves tool caches alone by default and drops them whole when asked" do
    Given "a store with two tool caches the tools have filled, and a locked engine"
    dir = Dir.mktmpdir("dev-cache-gc-test-")
    store = Dev::Deps::LocalStore.new(data_root: dir)
    (store.tool_cache("bundler") / "gems").mkpath
    (store.tool_cache("brew") / "bottle.tar.gz").write("bottle")
    base = engine_base(dir)
    seed_versions(base, "c")
    lockfile = lock_engine(dir, version: "c")
    out = StringIO.new
    gc = FixtureCacheGc.new(lockfile: lockfile, store: store, out: out)

    When "collecting without, then with, tool caches"
    gc.gc(keep: 2)
    untouched = store.tool_caches
    gc.gc(keep: 2, tool_caches: true)

    Then "the default pass never reaches into a tool's cache; the explicit pass removes each as a unit and says so"
    untouched == %w[brew bundler]
    store.tool_caches == []
    out.string.include?("removing tool cache #{dir}/tool-caches/brew")
    out.string.include?("removing tool cache #{dir}/tool-caches/bundler")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "gc removes orphan staging dirs left by a killed install" do
    Given "a published version and an orphan staging dir"
    dir = Dir.mktmpdir("dev-cache-gc-test-")
    base = engine_base(dir)
    seed_versions(base, "c")
    FileUtils.mkdir_p(File.join(base, ".staging-999-deadbeef"))
    lockfile = lock_engine(dir, version: "c")
    gc = build_gc(dir, lockfile, out: StringIO.new)

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
    base = engine_base(dir)
    seed_versions(base, "old", "mid", "new") # locked = old (oldest)
    lockfile = lock_engine(dir, version: "old")
    gc = build_gc(dir, lockfile, out: StringIO.new)

    When "collecting with keep: 2"
    gc.gc(keep: 2)

    Then "the locked oldest survives alongside the single newest; mid is reclaimed"
    Dir.children(base).sort == ["new", "old"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "running_mount_sources collects every running container's mount sources" do
    Given "an engine whose docker reports two containers with mounts"
    dir = Dir.mktmpdir("dev-cache-gc-test-")
    engine = FakeContainerEngine.new(capture_result: lambda { |args|
      case args
      when ["ps", "-q"] then "abc\ndef\n"
      when ["inspect", "--format", "{{range .Mounts}}{{.Source}}\n{{end}}", "abc", "def"]
        "/mnt/engine\n\n/mnt/cache\n"
      else ""
      end
    })
    gc = Dev::Deps::CacheGc.new(lockfile: Dev::Deps::Lockfile.new(dir: dir), engine: engine, out: StringIO.new)

    When "collecting mount sources"
    sources = gc.send(:running_mount_sources)

    Then "both sources are present, blank lines dropped"
    sources == Set.new(["/mnt/engine", "/mnt/cache"])

    Cleanup
    FileUtils.rm_rf(dir)
  end

  # A prefix volume whose name carries no host user (a renamed user's;
  # Linux's bare dev-linuxbrew from before the per-user split, #343) holds a
  # bootstrapped brew and every keg it poured, and nothing will mount it
  # again — unless a container from before still does, and that container
  # is its checkout's to recreate first.
  test "gc removes the stale prefix volumes no container mounts, keeps a mounted one and says why, and leaves live ones alone" do
    Given "an engine with both users' volumes, the legacy one still mounted by an old container, and a gone user's"
    dir = Dir.mktmpdir("dev-cache-gc-test-")
    engine = FakeContainerEngine.new(capture_result: lambda { |args|
      case args
      in ["volume", "ls", *] then "dev-linuxbrew\ndev-linuxbrew-runner\ndev-linuxbrew-olduser\ndev-linuxbrew-jp\n"
      in ["ps", "-a", "--filter", "volume=dev-linuxbrew", *] then "dev-snappy-linux-abc\n"
      else ""
      end
    })
    volumes = Dev::PrefixVolumes.new(engine: engine, host_os: "linux", user_exists: ->(name) { %w[jp runner].include?(name) })
    out = StringIO.new
    gc = Dev::Deps::CacheGc.new(lockfile: Dev::Deps::Lockfile.new(dir: dir), engine: engine, out: out, prefix_volumes: volumes)

    When
    gc.gc

    Then
    engine.runs.include?(["volume", "rm", "dev-linuxbrew-olduser"])
    engine.runs.select { |*run| run.flatten.first(2) == %w[volume rm] } == [["volume", "rm", "dev-linuxbrew-olduser"]]
    out.string.include?(">>> gc: removing prefix volume dev-linuxbrew-olduser (no host user olduser)\n")
    out.string.include?(">>> gc: keeping prefix volume dev-linuxbrew (no host user) — mounted by dev-snappy-linux-abc (dev container up there recreates it)\n")
    !out.string.include?("dev-linuxbrew-runner")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "gc_docker reaps every tag of a pinned image's repository but the lock's ref and the ones running containers back" do
    Given "a lock pinning snappy-linux at one digest; docker holds that tag, two older ones, one of them running"
    dir = Dir.mktmpdir("dev-cache-gc-test-")
    image = pinned_image("snappy-linux")
    engine = FakeContainerEngine.new(capture_result: lambda { |args|
      case args
      when ["images", image.repository, "--format", "{{.Repository}}:{{.Tag}}"]
        "#{image.repository}:#{"0" * 64}\n#{image.ref}\n#{image.repository}:#{"1" * 64}\n"
      when ["ps", "--format", "{{.Image}}"] then "#{image.repository}:#{"1" * 64}\n"
      else ""
      end
    })
    out = StringIO.new
    gc = Dev::Deps::CacheGc.new(lockfile: Dev::Deps::Lockfile.new(dir: dir), engine: engine, out: out)

    When "reaping for the lock's images"
    gc.send(:gc_docker, images: [image])

    Then "the one tag the lock does not name and no container runs is removed, and named"
    engine.runs == [["rmi", "#{image.repository}:#{"0" * 64}"]]
    out.string == ">>> gc: removing image #{image.repository}:#{"0" * 64}\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "gc_docker keeps to each pinned repository: another image's tags are never listed, and a project pinning none asks docker nothing" do
    Given "two pinned images, each repository holding only the lock's ref"
    dir = Dir.mktmpdir("dev-cache-gc-test-")
    linux = pinned_image("snappy-linux")
    server = pinned_image("snappy-server")
    listed = []
    engine = FakeContainerEngine.new(capture_result: lambda { |args|
      case args
      when ["images", linux.repository, "--format", "{{.Repository}}:{{.Tag}}"]
        listed << linux.repository
        "#{linux.ref}\n"
      when ["images", server.repository, "--format", "{{.Repository}}:{{.Tag}}"]
        listed << server.repository
        "#{server.ref}\n"
      else ""
      end
    })
    gc = Dev::Deps::CacheGc.new(lockfile: Dev::Deps::Lockfile.new(dir: dir), engine: engine, out: StringIO.new)

    When "reaping for both, then for none"
    gc.send(:gc_docker, images: [linux, server])
    gc.send(:gc_docker, images: [])

    Then "each repository was listed once, nothing removed, and the empty set touched docker not at all"
    listed == [linux.repository, server.repository]
    engine.runs.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "gc hands the images through to gc_docker beside the tree sweep" do
    Given "a lock, one pinned image, and a gc whose docker half records what it was asked"
    dir = Dir.mktmpdir("dev-cache-gc-test-")
    lockfile = lock_engine(dir, version: "5.6.1-css-83")
    image = pinned_image("snappy-linux")
    gc = build_gc(dir, lockfile)
    gc.expects(:gc_docker).with(images: [image]).once

    When
    gc.gc(keep: 2, images: [image])

    Then
    true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  # A lock's image, as the gc sees it (EnvironmentImage#repository, #ref).
  def pinned_image(name)
    Dev::EnvironmentImage.from_pin(
      Dev::Deps::Dependency.new(
        name: name, integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}",
        metadata: {
          "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platform" => "linux/amd64",
          "platforms" => ["linux/amd64"], "registry" => "ghcr.io/d3mlabs", "apt" => [],
        },
      ),
    )
  end
end
