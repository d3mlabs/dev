# frozen_string_literal: true

require "minitest/autorun"
require "dev/deps"
require "tmpdir"

class Dev::Deps::FetcherTest < Minitest::Test
  def test_update_lockfile_hash_inserts_new
    Dir.mktmpdir("dev-deps-test-") do |dir|
      lock_path = File.join(dir, "deps.lock.cmake")
      File.write(lock_path, <<~CMAKE)
        set(dep_boost_url "https://example.com/boost.tar.gz")
        set(RUNTIME_DEPS_APP "boost")
      CMAKE

      Dev::Deps::Fetcher.update_lockfile_hash(lock_path, "boost", "deadbeef")
      content = File.read(lock_path)
      assert_includes content, 'set(dep_boost_hash "SHA256=deadbeef")'
    end
  end

  def test_update_lockfile_hash_replaces_existing
    Dir.mktmpdir("dev-deps-test-") do |dir|
      lock_path = File.join(dir, "deps.lock.cmake")
      File.write(lock_path, <<~CMAKE)
        set(dep_boost_url "https://example.com/boost.tar.gz")
        set(dep_boost_hash "SHA256=oldhash")
        set(RUNTIME_DEPS_APP "boost")
      CMAKE

      Dev::Deps::Fetcher.update_lockfile_hash(lock_path, "boost", "newhash")
      content = File.read(lock_path)
      assert_includes content, 'set(dep_boost_hash "SHA256=newhash")'
      refute_includes content, "oldhash"
    end
  end
end
