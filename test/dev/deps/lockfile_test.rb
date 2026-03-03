# frozen_string_literal: true

require "minitest/autorun"
require "dev/deps"
require "tmpdir"

class Dev::Deps::LockfileTest < Minitest::Test
  def setup
    Dev::Deps::Config.instance_variable_set(:@config, nil)
  end

  def test_parse_git_deps
    Dir.mktmpdir("dev-deps-test-") do |dir|
      lockfile = File.join(dir, "deps.lock.cmake")
      File.write(lockfile, <<~CMAKE)
        set(dep_cereal_repo "https://github.com/USCiLab/cereal")
        set(dep_cereal_sha "abcdef1234567890abcdef1234567890abcdef12")
        set(RUNTIME_DEPS_APP "cereal")
      CMAKE

      deps = Dev::Deps::Lockfile.parse(lockfile)
      assert_equal 1, deps.size
      assert_equal "cereal", deps[0][:name]
      assert_equal "https://github.com/USCiLab/cereal", deps[0][:repo]
      assert_equal "abcdef1234567890abcdef1234567890abcdef12", deps[0][:sha]
    end
  end

  def test_parse_url_deps
    Dir.mktmpdir("dev-deps-test-") do |dir|
      lockfile = File.join(dir, "deps.lock.cmake")
      File.write(lockfile, <<~CMAKE)
        set(dep_boost_url "https://example.com/boost.tar.gz")
        set(dep_boost_hash "SHA256=abc123")
        set(RUNTIME_DEPS_APP "boost")
      CMAKE

      deps = Dev::Deps::Lockfile.parse(lockfile)
      assert_equal 1, deps.size
      assert_equal "boost", deps[0][:name]
      assert_equal "https://example.com/boost.tar.gz", deps[0][:url]
      assert_equal "SHA256=abc123", deps[0][:hash]
    end
  end

  def test_parse_mixed_app_and_test_deps
    Dir.mktmpdir("dev-deps-test-") do |dir|
      lockfile = File.join(dir, "deps.lock.cmake")
      File.write(lockfile, <<~CMAKE)
        set(dep_cereal_repo "https://github.com/USCiLab/cereal")
        set(dep_cereal_sha "abcdef1234567890abcdef1234567890abcdef12")
        set(dep_gtest_repo "https://github.com/google/googletest")
        set(dep_gtest_sha "1234567890abcdef1234567890abcdef12345678")
        set(RUNTIME_DEPS_APP "cereal")
        set(RUNTIME_DEPS_TEST "gtest")
      CMAKE

      deps = Dev::Deps::Lockfile.parse(lockfile)
      assert_equal 2, deps.size
      assert_equal "cereal", deps[0][:name]
      assert_equal "gtest", deps[1][:name]
    end
  end

  def test_out_of_sync_deps_detects_changed_sha
    current = <<~CMAKE
      set(dep_cereal_repo "https://github.com/USCiLab/cereal")
      set(dep_cereal_sha "aaaaaaa")
    CMAKE
    generated = <<~CMAKE
      set(dep_cereal_repo "https://github.com/USCiLab/cereal")
      set(dep_cereal_sha "bbbbbbb")
    CMAKE

    out_of_sync = Dev::Deps::Lockfile.out_of_sync_deps(current, generated)
    assert_equal ["cereal"], out_of_sync
  end

  def test_out_of_sync_deps_detects_no_diff
    content = <<~CMAKE
      set(dep_cereal_repo "https://github.com/USCiLab/cereal")
      set(dep_cereal_sha "aaaaaaa")
    CMAKE

    out_of_sync = Dev::Deps::Lockfile.out_of_sync_deps(content, content)
    assert_empty out_of_sync
  end

  def test_dep_pin_sha
    content = 'set(dep_cereal_sha "abcdef1234567890")'
    pin = Dev::Deps::Lockfile.dep_pin(content, "cereal")
    assert_equal "sha=abcdef1...", pin
  end

  def test_dep_pin_hash
    content = 'set(dep_boost_hash "SHA256=abcdef123456789012")'
    pin = Dev::Deps::Lockfile.dep_pin(content, "boost")
    assert_equal "hash=abcdef123456...", pin
  end

  def test_dep_pin_url_only
    content = 'set(dep_boost_url "https://example.com/boost.tar.gz")'
    pin = Dev::Deps::Lockfile.dep_pin(content, "boost")
    assert_equal "url=https://example.com/boost.tar.gz", pin
  end

  def test_dep_pin_missing
    pin = Dev::Deps::Lockfile.dep_pin("", "missing")
    assert_equal "(no pin)", pin
  end

  def test_runtime_ref_map
    Dev::Deps.define do
      group :app do
        runtime "boost", url: "https://example.com/boost.tar.gz", tag: "boost-1.90.0"
        runtime "entityx", repo: "https://github.com/example/entityx", commit: "abc123"
      end
      group :test do
        runtime "googletest", repo: "https://github.com/google/googletest", tag: "v1.17.0"
      end
    end

    ref_map = Dev::Deps::Lockfile.runtime_ref_map
    assert_equal "boost-1.90.0", ref_map["boost"]
    assert_equal "abc123", ref_map["entityx"]
    assert_equal "v1.17.0", ref_map["googletest"]
  end
end
