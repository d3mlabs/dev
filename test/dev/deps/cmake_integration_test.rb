# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/cmake_integration"
require "dev/deps/git_repository"
require "dev/deps/url_repository"
require "dev/deps/cache"
require "dev/deps/dependency"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::CmakeIntegrationTest < Minitest::Test
  def prepopulate_dep(root, name)
    dep_src = File.join(root, "build", "_deps", "#{name}-src")
    FileUtils.mkdir_p(dep_src)
    File.write(File.join(dep_src, "CMakeLists.txt"), "cmake_minimum_required(VERSION 3.20)")
  end

  test "install_all generates deps.cmake with repo+sha entries" do
    Given "a git-backed cmake dependency"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    git_repo = Dev::Deps::GitRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: git_repo, cache: cache, project_root: dir)
    prepopulate_dep(dir, "cereal")
    deps = [
      Dev::Deps::Dependency.new(
        name: "cereal", integration: :cmake, group: :app,
        version: "abc123def456", hash: nil,
        metadata: { "repo" => "https://github.com/USCiLab/cereal" },
      ),
    ]

    When "installing all"
    integration.install_all(deps)
    cmake_content = File.read(File.join(dir, "deps.cmake"))

    Then
    cmake_content.include?('set(dep_cereal_repo "https://github.com/USCiLab/cereal")')
    cmake_content.include?('set(dep_cereal_sha "abc123def456")')

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all generates deps.cmake with url+hash entries" do
    Given "a URL-backed cmake dependency"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    url_repo = Dev::Deps::UrlRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: url_repo, cache: cache, project_root: dir)
    prepopulate_dep(dir, "boost")
    deps = [
      Dev::Deps::Dependency.new(
        name: "boost", integration: :cmake, group: :app,
        version: "1.90.0", hash: "SHA256=deadbeef",
        metadata: { "url" => "https://example.com/boost.tar.gz" },
      ),
    ]

    When "installing all"
    integration.install_all(deps)
    cmake_content = File.read(File.join(dir, "deps.cmake"))

    Then
    cmake_content.include?('set(dep_boost_url "https://example.com/boost.tar.gz")')
    cmake_content.include?('set(dep_boost_hash "SHA256=deadbeef")')

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all generates RUNTIME_DEPS_APP and RUNTIME_DEPS_TEST lists" do
    Given "app and test cmake dependencies"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    git_repo = Dev::Deps::GitRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: git_repo, cache: cache, project_root: dir)
    prepopulate_dep(dir, "boost")
    prepopulate_dep(dir, "gtest")
    deps = [
      Dev::Deps::Dependency.new(name: "boost", integration: :cmake, group: :app,
                                version: "sha1", hash: nil,
                                metadata: { "repo" => "https://github.com/boost/boost" }),
      Dev::Deps::Dependency.new(name: "gtest", integration: :cmake, group: :test,
                                version: "sha2", hash: nil,
                                metadata: { "repo" => "https://github.com/google/googletest" }),
    ]

    When "installing all"
    integration.install_all(deps)
    cmake_content = File.read(File.join(dir, "deps.cmake"))

    Then
    cmake_content.include?('set(RUNTIME_DEPS_APP "boost")')
    cmake_content.include?('set(RUNTIME_DEPS_TEST "gtest")')

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all generates deps.targets.cmake with cmake_targets" do
    Given "a dependency with cmake targets and namespace"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    git_repo = Dev::Deps::GitRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: git_repo, cache: cache, project_root: dir)
    prepopulate_dep(dir, "googletest")
    deps = [
      Dev::Deps::Dependency.new(
        name: "googletest", integration: :cmake, group: :test,
        version: "sha1", hash: nil,
        metadata: {
          "repo" => "https://github.com/google/googletest",
          "cmake_targets" => ["gtest", "gmock"],
          "cmake_namespace" => "GTest::",
        },
      ),
    ]

    When "installing all"
    integration.install_all(deps)
    targets_content = File.read(File.join(dir, "deps.targets.cmake"))

    Then
    targets_content.include?('set(dep_googletest_cmake_targets "gtest;gmock")')
    targets_content.include?('set(dep_googletest_cmake_namespace "GTest::")')

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
