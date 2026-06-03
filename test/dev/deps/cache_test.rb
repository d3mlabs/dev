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
    cache = Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache"))

    Expect
    !cache.exists?("cmake/boost-1.90.0-deadbeef.tar.gz")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "store moves artifact into cache, fetch retrieves it" do
    Given "a cache and a source artifact"
    dir = Dir.mktmpdir("dev-cache-test-")
    cache = Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache"))
    artifact_path = File.join(dir, "download.tar.gz")
    File.write(artifact_path, "fake tarball content")
    key = "cmake/boost-1.90.0-deadbeef.tar.gz"

    When "storing with a structured key"
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
    cache = Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache"))
    artifact_path = File.join(dir, "download.zip")
    File.write(artifact_path, "original content")
    key = "luarocks/luaunit-3.5-1-abc123.rock"

    When "storing the artifact"
    File.open(artifact_path, "rb") { |f| cache.store(key, f) }

    Then
    !File.exist?(artifact_path)
    cache.exists?(key)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "fetch raises CacheMissError for missing key" do
    Given "an empty cache"
    dir = Dir.mktmpdir("dev-cache-test-")
    cache = Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache"))

    When "fetching a non-existent key"
    cache.fetch("cmake/missing-1.0.0-000000.tar.gz")

    Then
    raises Dev::Deps::Cache::CacheMissError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "store creates integration subdirectory if it does not exist" do
    Given "a cache with no integration subdirectory yet"
    dir = Dir.mktmpdir("dev-cache-test-")
    cache_dir = File.join(dir, "cache")
    cache = Dev::Deps::Cache.new(cache_dir: cache_dir)
    artifact_path = File.join(dir, "data.zip")
    File.write(artifact_path, "zip content")
    key = "wow_curseforge/CombatMode-2.3.0-abc123.zip"

    When "storing an artifact"
    File.open(artifact_path, "rb") { |f| cache.store(key, f) }

    Then
    cache.exists?(key)
    Dir.exist?(File.join(cache_dir, "wow_curseforge"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "fetch returns a File handle" do
    Given "a cache with a stored artifact"
    dir = Dir.mktmpdir("dev-cache-test-")
    cache = Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache"))
    artifact_path = File.join(dir, "pkg.tar.gz")
    File.write(artifact_path, "content")
    key = "brew/lua-5.1-typed.tar.gz"
    File.open(artifact_path, "rb") { |f| cache.store(key, f) }

    When "fetching the stored key"
    result = cache.fetch(key)

    Then
    result.is_a?(File)

    Cleanup
    result&.close
    FileUtils.rm_rf(dir)
  end

  test "different integrations are stored in separate subdirectories" do
    Given "a cache with artifacts from two integrations"
    dir = Dir.mktmpdir("dev-cache-test-")
    cache = Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache"))
    cmake_artifact = File.join(dir, "cmake_dl.tar.gz")
    luarocks_artifact = File.join(dir, "luarocks_dl.rock")
    File.write(cmake_artifact, "cmake content")
    File.write(luarocks_artifact, "luarocks content")

    When "storing both"
    File.open(cmake_artifact, "rb") { |f| cache.store("cmake/boost-1.0-aaa.tar.gz", f) }
    File.open(luarocks_artifact, "rb") { |f| cache.store("luarocks/luaunit-3.5-bbb.rock", f) }

    Then
    cache.exists?("cmake/boost-1.0-aaa.tar.gz")
    cache.exists?("luarocks/luaunit-3.5-bbb.rock")
    cache.fetch("cmake/boost-1.0-aaa.tar.gz").read == "cmake content"
    cache.fetch("luarocks/luaunit-3.5-bbb.rock").read == "luarocks content"

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
