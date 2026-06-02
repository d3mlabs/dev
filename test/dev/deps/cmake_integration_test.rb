# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/cmake_integration"
require "dev/deps/git_repository"
require "dev/deps/url_repository"
require "dev/deps/cache"
require "dev/deps/pin"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::CmakeIntegrationTest < Minitest::Test
  test "install_all generates deps.cmake with repo+sha entries" do
    Given
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    git_repo = Dev::Deps::GitRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: git_repo, cache: cache)
    pins = [
      Dev::Deps::Pin.new(
        name: "cereal", integration: :cmake, group: :app,
        version: "abc123def456", hash: nil,
        metadata: { "repo" => "https://github.com/USCiLab/cereal" },
      ),
    ]

    # Stub the actual git clone since we only test CMake file generation
    integration.stubs(:fetch_pin)

    When
    integration.install_all(pins, root: dir)
    cmake_content = File.read(File.join(dir, "deps.cmake"))

    Then
    cmake_content.include?('set(dep_cereal_repo "https://github.com/USCiLab/cereal")')
    cmake_content.include?('set(dep_cereal_sha "abc123def456")')

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all generates deps.cmake with url+hash entries" do
    Given
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    url_repo = Dev::Deps::UrlRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: url_repo, cache: cache)
    pins = [
      Dev::Deps::Pin.new(
        name: "boost", integration: :cmake, group: :app,
        version: "1.90.0", hash: "SHA256=deadbeef",
        metadata: { "url" => "https://example.com/boost.tar.gz" },
      ),
    ]

    integration.stubs(:fetch_pin)

    When
    integration.install_all(pins, root: dir)
    cmake_content = File.read(File.join(dir, "deps.cmake"))

    Then
    cmake_content.include?('set(dep_boost_url "https://example.com/boost.tar.gz")')
    cmake_content.include?('set(dep_boost_hash "SHA256=deadbeef")')

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all generates RUNTIME_DEPS_APP and RUNTIME_DEPS_TEST lists" do
    Given
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    git_repo = Dev::Deps::GitRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: git_repo, cache: cache)
    pins = [
      Dev::Deps::Pin.new(name: "boost", integration: :cmake, group: :app,
                          version: "sha1", hash: nil,
                          metadata: { "repo" => "https://github.com/boost/boost" }),
      Dev::Deps::Pin.new(name: "gtest", integration: :cmake, group: :test,
                          version: "sha2", hash: nil,
                          metadata: { "repo" => "https://github.com/google/googletest" }),
    ]

    integration.stubs(:fetch_pin)

    When
    integration.install_all(pins, root: dir)
    cmake_content = File.read(File.join(dir, "deps.cmake"))

    Then
    cmake_content.include?('set(RUNTIME_DEPS_APP "boost")')
    cmake_content.include?('set(RUNTIME_DEPS_TEST "gtest")')

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all generates deps.targets.cmake with cmake_targets" do
    Given
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    git_repo = Dev::Deps::GitRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: git_repo, cache: cache)
    pins = [
      Dev::Deps::Pin.new(
        name: "googletest", integration: :cmake, group: :test,
        version: "sha1", hash: nil,
        metadata: {
          "repo" => "https://github.com/google/googletest",
          "cmake_targets" => ["gtest", "gmock"],
          "cmake_namespace" => "GTest::",
        },
      ),
    ]

    integration.stubs(:fetch_pin)

    When
    integration.install_all(pins, root: dir)
    targets_content = File.read(File.join(dir, "deps.targets.cmake"))

    Then
    targets_content.include?('set(dep_googletest_cmake_targets "gtest;gmock")')
    targets_content.include?('set(dep_googletest_cmake_namespace "GTest::")')

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
