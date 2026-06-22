# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/ficsit_integration"
require "dev/deps/ficsit_repository"
require "dev/deps/cache"
require "dev/deps/dependency"
require "digest"
require "tmpdir"

# FicsitIntegration with the curl download boundary replaced by copying a
# pre-built fixture zip. Everything else (SHA256 verification, cache.store,
# skip-when-cached) runs for real against the filesystem.
class FixtureFicsitIntegration < Dev::Deps::FicsitIntegration
  attr_reader :download_count

  def initialize(fixtures:, **kwargs)
    super(**kwargs)
    @fixtures = fixtures
    @download_count = 0
  end

  private

  def download(link, dest)
    @download_count += 1
    FileUtils.cp(@fixtures.fetch(link), dest)
  end
end unless defined?(FixtureFicsitIntegration)

transform!(RSpock::AST::Transformation)
class Dev::Deps::FicsitIntegrationTest < Minitest::Test
  # Write a fixture zip with deterministic bytes and return [path, "SHA256=…"].
  def build_fixture(dir, name, payload)
    path = File.join(dir, name)
    File.binwrite(path, payload)
    [path, "SHA256=#{Digest::SHA256.hexdigest(payload)}"]
  end

  def build_dependency(platforms)
    Dev::Deps::Dependency.new(
      name: "SML", integration: :ficsit, group: :app,
      version: "3.12.0", hash: nil,
      metadata: { "platforms" => platforms },
    )
  end

  test "install_all downloads, verifies, and caches every locked platform" do
    Given "an SML dep resolved for Windows and LinuxServer"
    dir = Dir.mktmpdir("dev-ficsit-int-test-")
    win_path, win_hash = build_fixture(dir, "win.zip", "windows-mod-bytes")
    lin_path, lin_hash = build_fixture(dir, "lin.zip", "linux-mod-bytes")
    win_link = "https://api.ficsit.app/v1/version/ver1/Windows/download"
    lin_link = "https://api.ficsit.app/v1/version/ver1/LinuxServer/download"
    dep = build_dependency(
      "Windows" => { "hash" => win_hash, "link" => win_link },
      "LinuxServer" => { "hash" => lin_hash, "link" => lin_link },
    )
    cache = Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache"))
    integration = FixtureFicsitIntegration.new(
      fixtures: { win_link => win_path, lin_link => lin_path },
      repository: Dev::Deps::FicsitRepository.new, cache: cache,
    )

    When "installing"
    integration.install_all([dep])

    Then "both platform zips are cached under the shared key scheme"
    win_key = Dev::Deps::FicsitIntegration.cache_key(
      name: "SML", version: "3.12.0", platform: "Windows", hash: win_hash,
    )
    lin_key = Dev::Deps::FicsitIntegration.cache_key(
      name: "SML", version: "3.12.0", platform: "LinuxServer", hash: lin_hash,
    )
    cache.exists?(win_key)
    cache.exists?(lin_key)
    integration.download_count == 2

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all skips a platform already present in the cache" do
    Given "a cache already holding the Windows zip"
    dir = Dir.mktmpdir("dev-ficsit-int-test-")
    win_path, win_hash = build_fixture(dir, "win.zip", "windows-mod-bytes")
    win_link = "https://api.ficsit.app/v1/version/ver1/Windows/download"
    dep = build_dependency("Windows" => { "hash" => win_hash, "link" => win_link })
    cache = Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache"))
    key = Dev::Deps::FicsitIntegration.cache_key(
      name: "SML", version: "3.12.0", platform: "Windows", hash: win_hash,
    )
    File.open(win_path, "rb") { |f| cache.store(key, f) }
    integration = FixtureFicsitIntegration.new(
      fixtures: {}, repository: Dev::Deps::FicsitRepository.new, cache: cache,
    )

    When "installing again"
    integration.install_all([dep])

    Then "no download happens"
    integration.download_count == 0

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises IntegrityError and caches nothing on a hash mismatch" do
    Given "a locked hash that does not match the downloaded bytes"
    dir = Dir.mktmpdir("dev-ficsit-int-test-")
    win_path, = build_fixture(dir, "win.zip", "windows-mod-bytes")
    win_link = "https://api.ficsit.app/v1/version/ver1/Windows/download"
    bad_hash = "SHA256=#{"0" * 64}"
    dep = build_dependency("Windows" => { "hash" => bad_hash, "link" => win_link })
    cache = Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache"))
    integration = FixtureFicsitIntegration.new(
      fixtures: { win_link => win_path },
      repository: Dev::Deps::FicsitRepository.new, cache: cache,
    )

    When "installing tampered bytes"
    error = assert_raises(Dev::Deps::FicsitIntegration::IntegrityError) do
      integration.install_all([dep])
    end

    Then
    error.message.include?("SML")
    key = Dev::Deps::FicsitIntegration.cache_key(
      name: "SML", version: "3.12.0", platform: "Windows", hash: bad_hash,
    )
    !cache.exists?(key)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises MissingPlatformsError when the dep has no platforms" do
    Given "a ficsit dep resolved without platform info"
    dir = Dir.mktmpdir("dev-ficsit-int-test-")
    dep = Dev::Deps::Dependency.new(
      name: "SML", integration: :ficsit, group: :app,
      version: "3.12.0", hash: "SHA256=abc", metadata: { "target" => "Windows" },
    )
    integration = FixtureFicsitIntegration.new(
      fixtures: {}, repository: Dev::Deps::FicsitRepository.new,
      cache: Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache")),
    )

    When "installing"
    integration.install_all([dep])

    Then
    raises Dev::Deps::FicsitIntegration::MissingPlatformsError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "cache_key strips the SHA256 prefix and embeds name, version, platform" do
    When "building a cache key"
    key = Dev::Deps::FicsitIntegration.cache_key(
      name: "SML", version: "3.12.0", platform: "LinuxServer", hash: "SHA256=deadbeef",
    )

    Then
    key == "ficsit/SML-3.12.0-LinuxServer-deadbeef.zip"
  end
end
