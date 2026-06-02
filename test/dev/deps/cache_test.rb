# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/cache"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class Dev::Deps::CacheTest < Minitest::Test
  test "has? returns false for missing hash" do
    Given
    dir = Dir.mktmpdir("dev-cache-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)

    Expect
    !cache.has?("SHA256=deadbeef")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "store places artifact in cache, fetch retrieves it" do
    Given
    dir = Dir.mktmpdir("dev-cache-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    artifact = File.join(dir, "boost.tar.gz")
    File.write(artifact, "fake tarball content")
    hash = "SHA256=deadbeef"

    When
    cache.store(hash, artifact)

    Then
    cache.has?(hash)
    cached_path = cache.fetch(hash)
    !cached_path.nil?
    File.read(cached_path) == "fake tarball content"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "fetch returns nil for missing hash" do
    Given
    dir = Dir.mktmpdir("dev-cache-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)

    Expect
    cache.fetch("SHA256=nonexistent").nil?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "store creates cache directory if it does not exist" do
    Given
    dir = Dir.mktmpdir("dev-cache-test-")
    cache_dir = File.join(dir, "nested", "cache")
    cache = Dev::Deps::Cache.new(cache_dir: cache_dir)
    artifact = File.join(dir, "data.zip")
    File.write(artifact, "zip content")

    When
    cache.store("SHA256=abc123", artifact)

    Then
    cache.has?("SHA256=abc123")
    Dir.exist?(cache_dir)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "store copies the file rather than moving it" do
    Given
    dir = Dir.mktmpdir("dev-cache-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    artifact = File.join(dir, "source.tar.gz")
    File.write(artifact, "original content")

    When
    cache.store("SHA256=keep", artifact)

    Then "original file still exists"
    File.exist?(artifact)
    cache.has?("SHA256=keep")

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
