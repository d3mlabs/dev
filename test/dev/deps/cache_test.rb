# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/cache"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class Dev::Deps::CacheTest < Minitest::Test
  test "exists? returns false for missing key" do
    Given "an empty cache"
    dir = Dir.mktmpdir("dev-cache-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)

    Expect
    !cache.exists?("SHA256=deadbeef")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "store moves artifact into cache, fetch retrieves it" do
    Given "a cache and an artifact file"
    dir = Dir.mktmpdir("dev-cache-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    artifact_path = File.join(dir, "boost.tar.gz")
    File.write(artifact_path, "fake tarball content")
    key = "SHA256=deadbeef"

    When "storing via File handle"
    File.open(artifact_path, "rb") { |f| cache.store(key, f) }

    Then
    cache.exists?(key)
    file = cache.fetch(key)
    file.is_a?(File)
    file.read == "fake tarball content"

    Cleanup
    file&.close
    FileUtils.rm_rf(dir)
  end

  test "store takes ownership — original file no longer exists" do
    Given "a cache and a source artifact"
    dir = Dir.mktmpdir("dev-cache-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    artifact_path = File.join(dir, "source.tar.gz")
    File.write(artifact_path, "original content")

    When "storing the artifact"
    File.open(artifact_path, "rb") { |f| cache.store("SHA256=moved", f) }

    Then
    !File.exist?(artifact_path)
    cache.exists?("SHA256=moved")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "fetch raises CacheMissError for missing key" do
    Given "an empty cache"
    dir = Dir.mktmpdir("dev-cache-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)

    When "fetching a non-existent key"
    error = begin
      cache.fetch("SHA256=nonexistent")
      nil
    rescue Dev::Deps::Cache::CacheMissError => e
      e
    end

    Then
    !error.nil?
    error.is_a?(Dev::Deps::Cache::CacheMissError)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "store creates cache directory if it does not exist" do
    Given "a cache pointing to a non-existent directory"
    dir = Dir.mktmpdir("dev-cache-test-")
    cache_dir = File.join(dir, "nested", "cache")
    cache = Dev::Deps::Cache.new(cache_dir: cache_dir)
    artifact_path = File.join(dir, "data.zip")
    File.write(artifact_path, "zip content")

    When "storing an artifact"
    File.open(artifact_path, "rb") { |f| cache.store("SHA256=abc123", f) }

    Then
    cache.exists?("SHA256=abc123")
    Dir.exist?(cache_dir)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "fetch returns a File handle" do
    Given "a cache with a stored artifact"
    dir = Dir.mktmpdir("dev-cache-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    artifact_path = File.join(dir, "data.tar.gz")
    File.write(artifact_path, "content")
    File.open(artifact_path, "rb") { |f| cache.store("SHA256=typed", f) }

    When "fetching the stored key"
    result = cache.fetch("SHA256=typed")

    Then
    result.is_a?(File)

    Cleanup
    result&.close
    FileUtils.rm_rf(dir)
  end
end
