# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/cache"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class Dev::Deps::CacheTest < Minitest::Test
  test "key? returns false for missing key" do
    Given "an empty cache"
    dir = Dir.mktmpdir("dev-cache-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)

    Expect
    !cache.key?("SHA256=deadbeef")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "store moves artifact into cache, fetch retrieves it" do
    Given "a cache and an artifact file"
    dir = Dir.mktmpdir("dev-cache-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    artifact = File.join(dir, "boost.tar.gz")
    File.write(artifact, "fake tarball content")
    key = "SHA256=deadbeef"

    When
    cache.store(key, artifact)

    Then
    cache.key?(key)
    cached_path = cache.fetch(key)
    !cached_path.nil?
    File.read(cached_path) == "fake tarball content"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "store takes ownership — original file no longer exists" do
    Given "a cache and a source artifact"
    dir = Dir.mktmpdir("dev-cache-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    artifact = File.join(dir, "source.tar.gz")
    File.write(artifact, "original content")

    When
    cache.store("SHA256=moved", artifact)

    Then
    !File.exist?(artifact)
    cache.key?("SHA256=moved")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "fetch returns nil for missing key" do
    Given "an empty cache"
    dir = Dir.mktmpdir("dev-cache-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)

    Expect
    cache.fetch("SHA256=nonexistent").nil?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "store creates cache directory if it does not exist" do
    Given "a cache pointing to a non-existent directory"
    dir = Dir.mktmpdir("dev-cache-test-")
    cache_dir = File.join(dir, "nested", "cache")
    cache = Dev::Deps::Cache.new(cache_dir: cache_dir)
    artifact = File.join(dir, "data.zip")
    File.write(artifact, "zip content")

    When
    cache.store("SHA256=abc123", artifact)

    Then
    cache.key?("SHA256=abc123")
    Dir.exist?(cache_dir)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "Key rejects blank values" do
    Given "blank key inputs"

    When
    nil_error = begin
      Dev::Deps::Cache::Key.new(nil)
      nil
    rescue ArgumentError => e
      e
    end
    empty_error = begin
      Dev::Deps::Cache::Key.new("   ")
      nil
    rescue ArgumentError => e
      e
    end

    Then
    !nil_error.nil?
    !empty_error.nil?
  end

  test "fetch returns Pathname" do
    Given "a cache with a stored artifact"
    dir = Dir.mktmpdir("dev-cache-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    artifact = File.join(dir, "data.tar.gz")
    File.write(artifact, "content")
    cache.store("SHA256=typed", artifact)

    When
    result = cache.fetch("SHA256=typed")

    Then
    result.is_a?(Pathname)

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
