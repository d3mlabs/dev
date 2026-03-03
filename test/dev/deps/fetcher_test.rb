# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::FetcherTest < Minitest::Test
  test "update_lockfile_hash inserts new hash after url entry" do
    Given "a lockfile without a hash entry"
    dir = Dir.mktmpdir("dev-deps-test-")
    lock_path = File.join(dir, "deps.lock.cmake")
    File.write(lock_path, <<~CMAKE)
      set(dep_boost_url "https://example.com/boost.tar.gz")
      set(RUNTIME_DEPS_APP "boost")
    CMAKE

    When "updating the hash"
    Dev::Deps::Fetcher.update_lockfile_hash(lock_path, "boost", "deadbeef")

    Then
    content = File.read(lock_path)
    content.include?('set(dep_boost_hash "SHA256=deadbeef")')

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "update_lockfile_hash replaces existing hash" do
    Given "a lockfile with an existing hash entry"
    dir = Dir.mktmpdir("dev-deps-test-")
    lock_path = File.join(dir, "deps.lock.cmake")
    File.write(lock_path, <<~CMAKE)
      set(dep_boost_url "https://example.com/boost.tar.gz")
      set(dep_boost_hash "SHA256=oldhash")
      set(RUNTIME_DEPS_APP "boost")
    CMAKE

    When "updating the hash"
    Dev::Deps::Fetcher.update_lockfile_hash(lock_path, "boost", "newhash")

    Then
    content = File.read(lock_path)
    content.include?('set(dep_boost_hash "SHA256=newhash")')
    !content.include?("oldhash")

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
