# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::LockfileTest < Minitest::Test
  def setup
    Dev::Deps::Config.instance_variable_set(:@config, nil)
  end

  test "parse extracts git deps" do
    Given "a lockfile with a git-based dep"
    dir = Dir.mktmpdir("dev-deps-test-")
    lock_path = File.join(dir, "deps.lock.cmake")
    File.write(lock_path, <<~CMAKE)
      set(dep_cereal_repo "https://github.com/USCiLab/cereal")
      set(dep_cereal_sha "abcdef1234567890abcdef1234567890abcdef12")
      set(RUNTIME_DEPS_APP "cereal")
    CMAKE

    When "parsing"
    deps = Dev::Deps::Lockfile.parse(lock_path)

    Then
    deps.size == 1
    deps[0][:name] == "cereal"
    deps[0][:repo] == "https://github.com/USCiLab/cereal"
    deps[0][:sha] == "abcdef1234567890abcdef1234567890abcdef12"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "parse extracts url deps" do
    Given "a lockfile with a url-based dep"
    dir = Dir.mktmpdir("dev-deps-test-")
    lock_path = File.join(dir, "deps.lock.cmake")
    File.write(lock_path, <<~CMAKE)
      set(dep_boost_url "https://example.com/boost.tar.gz")
      set(dep_boost_hash "SHA256=abc123")
      set(RUNTIME_DEPS_APP "boost")
    CMAKE

    When "parsing"
    deps = Dev::Deps::Lockfile.parse(lock_path)

    Then
    deps.size == 1
    deps[0][:name] == "boost"
    deps[0][:url] == "https://example.com/boost.tar.gz"
    deps[0][:hash] == "SHA256=abc123"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "parse extracts mixed app and test deps" do
    Given "a lockfile with both app and test deps"
    dir = Dir.mktmpdir("dev-deps-test-")
    lock_path = File.join(dir, "deps.lock.cmake")
    File.write(lock_path, <<~CMAKE)
      set(dep_cereal_repo "https://github.com/USCiLab/cereal")
      set(dep_cereal_sha "abcdef1234567890abcdef1234567890abcdef12")
      set(dep_gtest_repo "https://github.com/google/googletest")
      set(dep_gtest_sha "1234567890abcdef1234567890abcdef12345678")
      set(RUNTIME_DEPS_APP "cereal")
      set(RUNTIME_DEPS_TEST "gtest")
    CMAKE

    When "parsing"
    deps = Dev::Deps::Lockfile.parse(lock_path)

    Then
    deps.size == 2
    deps[0][:name] == "cereal"
    deps[1][:name] == "gtest"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "out_of_sync_deps detects changed sha" do
    Given "two lockfile contents with different shas"
    current = <<~CMAKE
      set(dep_cereal_repo "https://github.com/USCiLab/cereal")
      set(dep_cereal_sha "aaaaaaa")
    CMAKE
    generated = <<~CMAKE
      set(dep_cereal_repo "https://github.com/USCiLab/cereal")
      set(dep_cereal_sha "bbbbbbb")
    CMAKE

    Expect
    Dev::Deps::Lockfile.out_of_sync_deps(current, generated) == ["cereal"]
  end

  test "out_of_sync_deps returns empty when identical" do
    Given "identical lockfile contents"
    content = <<~CMAKE
      set(dep_cereal_repo "https://github.com/USCiLab/cereal")
      set(dep_cereal_sha "aaaaaaa")
    CMAKE

    Expect
    Dev::Deps::Lockfile.out_of_sync_deps(content, content).empty?
  end

  test "dep_pin returns #{expected} for #{label}" do
    Expect
    Dev::Deps::Lockfile.dep_pin(content, name) == expected

    Where
    label        | content                                                   | name      | expected
    "sha"        | 'set(dep_cereal_sha "abcdef1234567890")'                  | "cereal"  | "sha=abcdef1..."
    "hash"       | 'set(dep_boost_hash "SHA256=abcdef123456789012")'         | "boost"   | "hash=abcdef123456..."
    "url only"   | 'set(dep_boost_url "https://example.com/boost.tar.gz")'   | "boost"   | "url=https://example.com/boost.tar.gz"
    "missing"    | ""                                                        | "missing" | "(no pin)"
  end

  test "runtime_ref_map returns tag and commit refs" do
    Given "config with app and test runtime deps"
    Dev::Deps.define do
      group :app do
        runtime "boost", url: "https://example.com/boost.tar.gz", tag: "boost-1.90.0"
        runtime "entityx", repo: "https://github.com/example/entityx", commit: "abc123"
      end
      group :test do
        runtime "googletest", repo: "https://github.com/google/googletest", tag: "v1.17.0"
      end
    end

    When "building the ref map"
    ref_map = Dev::Deps::Lockfile.runtime_ref_map

    Then
    ref_map["boost"] == "boost-1.90.0"
    ref_map["entityx"] == "abc123"
    ref_map["googletest"] == "v1.17.0"
  end
end
