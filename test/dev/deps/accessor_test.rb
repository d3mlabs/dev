# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/accessor"
require "dev/deps/lockfile"
require "dev/deps/cache"
require "dev/deps/dependency"
require "dev/deps/ficsit_integration"
require "dev/deps/xcode_integration"
require "pathname"
require "tmpdir"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Deps::AccessorTest < Minitest::Test
  # Lock an SML dep with the given platforms and seed the cache for each.
  def setup_locked_sml(dir, platforms:, cache_platforms: platforms.keys)
    lockfile = Dev::Deps::Lockfile.new(dir: dir)
    dep = Dev::Deps::Dependency.new(
      name: "SML", integration: :ficsit, group: :app,
      version: "3.12.0", hash: nil, metadata: { "platforms" => platforms },
    )
    lockfile.lock([dep])

    cache = Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache"))
    cache_platforms.each do |platform|
      key = Dev::Deps::FicsitIntegration.cache_key(
        name: "SML", version: "3.12.0", platform: platform, hash: platforms[platform]["hash"],
      )
      artifact = File.join(dir, "#{platform}.zip")
      File.binwrite(artifact, "#{platform}-bytes")
      File.open(artifact, "rb") { |f| cache.store(key, f) }
    end

    [Dev::Deps::Accessor.new(lockfile: lockfile, cache: cache), cache]
  end

  def linux_platforms
    {
      "Windows" => { "hash" => "SHA256=#{"a" * 64}", "link" => "https://example/win" },
      "LinuxServer" => { "hash" => "SHA256=#{"b" * 64}", "link" => "https://example/lin" },
    }
  end

  # Lock an xcode pin and return an accessor whose install root is inside dir.
  def setup_locked_xcode(dir, version: "26.1.1", installed: true)
    lockfile = Dev::Deps::Lockfile.new(dir: dir)
    lockfile.lock([
      Dev::Deps::Dependency.new(
        name: "xcode", integration: :xcode, group: :build,
        version: version, hash: nil, metadata: {},
      ),
    ])
    install_root = File.join(dir, "Applications")
    developer_dir = Dev::Deps::XcodeIntegration.developer_dir(version, root: install_root)
    FileUtils.mkdir_p(developer_dir) if installed

    accessor = Dev::Deps::Accessor.new(
      lockfile: lockfile,
      cache: Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache")),
      xcode_install_root: install_root,
    )
    [accessor, developer_dir]
  end

  test "path xcode returns the pinned DEVELOPER_DIR" do
    Given "a locked and installed xcode pin"
    dir = Dir.mktmpdir("dev-accessor-test-")
    accessor, developer_dir = setup_locked_xcode(dir)

    When "asking for the xcode path"
    result = accessor.path("xcode")

    Then
    result == Pathname(developer_dir)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "path xcode raises NotInstalledError when the pin is not on disk" do
    Given "a locked but uninstalled xcode pin"
    dir = Dir.mktmpdir("dev-accessor-test-")
    accessor, = setup_locked_xcode(dir, installed: false)

    When "asking for the xcode path"
    error = assert_raises(Dev::Deps::Accessor::NotInstalledError) do
      accessor.path("xcode")
    end

    Then "the fix is dev up"
    error.message.include?("run dev up")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "path xcode raises NotLockedError without an xcode pin in the lockfile" do
    Given "a lockfile without any xcode dep"
    dir = Dir.mktmpdir("dev-accessor-test-")
    accessor, = setup_locked_sml(dir, platforms: linux_platforms)

    When "asking for the xcode path"
    error = assert_raises(Dev::Deps::Accessor::NotLockedError) do
      accessor.path("xcode")
    end

    Then "the fix is update-deps"
    error.message.include?("run dev update-deps")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "path returns the cached zip path for a locked dep platform" do
    Given "a locked SML with cached Windows and LinuxServer zips"
    dir = Dir.mktmpdir("dev-accessor-test-")
    accessor, cache = setup_locked_sml(dir, platforms: linux_platforms)

    When "asking for the LinuxServer path"
    result = accessor.path("ficsit", "SML", "LinuxServer")

    Then "it matches the cache key path and the file exists"
    expected = cache.path(Dev::Deps::FicsitIntegration.cache_key(
      name: "SML", version: "3.12.0", platform: "LinuxServer", hash: linux_platforms["LinuxServer"]["hash"],
    ))
    result == expected
    File.exist?(result)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "run path prints the cached path to the output stream" do
    Given "a locked SML with a cached Windows zip"
    dir = Dir.mktmpdir("dev-accessor-test-")
    accessor, = setup_locked_sml(dir, platforms: linux_platforms)
    out = StringIO.new

    When "running deps path ficsit SML Windows"
    accessor.run(["path", "ficsit", "SML", "Windows"], out: out)

    Then
    out.string.strip.end_with?("Windows-#{"a" * 64}.zip")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "path raises NotLockedError when the dep is not in the lockfile" do
    Given "an empty lockfile"
    dir = Dir.mktmpdir("dev-accessor-test-")
    accessor = Dev::Deps::Accessor.new(
      lockfile: Dev::Deps::Lockfile.new(dir: dir),
      cache: Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache")),
    )

    When "asking for a path"
    accessor.path("ficsit", "SML", "LinuxServer")

    Then
    raises Dev::Deps::Accessor::NotLockedError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "path raises PlatformNotLockedError when the platform is absent" do
    Given "a locked SML without a WindowsServer platform"
    dir = Dir.mktmpdir("dev-accessor-test-")
    accessor, = setup_locked_sml(dir, platforms: linux_platforms)

    When "asking for an unlocked platform"
    accessor.path("ficsit", "SML", "WindowsServer")

    Then
    raises Dev::Deps::Accessor::PlatformNotLockedError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "path raises NotCachedError when the zip is locked but missing from the cache" do
    Given "a locked LinuxServer platform whose zip was never cached"
    dir = Dir.mktmpdir("dev-accessor-test-")
    accessor, = setup_locked_sml(dir, platforms: linux_platforms, cache_platforms: ["Windows"])

    When "asking for the uncached LinuxServer path"
    accessor.path("ficsit", "SML", "LinuxServer")

    Then
    raises Dev::Deps::Accessor::NotCachedError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "run raises UsageError for an unknown subcommand" do
    Given "an accessor"
    dir = Dir.mktmpdir("dev-accessor-test-")
    accessor = Dev::Deps::Accessor.new(
      lockfile: Dev::Deps::Lockfile.new(dir: dir),
      cache: Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache")),
    )

    When "running an unknown subcommand"
    accessor.run(["bogus"])

    Then
    raises Dev::Deps::Accessor::UsageError

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
