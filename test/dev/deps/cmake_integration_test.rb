# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/cmake_integration"
require "dev/deps/git_repository"
require "dev/deps/url_repository"
require "dev/deps/resolver"
require "dev/deps/dependency_declaration"
require "dev/deps/cache"
require "dev/deps/dependency"
require "tmpdir"

# Stub repository for end-to-end resolver tests.
class StubRepository < Dev::Deps::Repository
  def initialize(deps_by_name: {})
    @deps_by_name = deps_by_name
  end

  def fetch(id)
    @deps_by_name.fetch(id["name"])
  end
end unless defined?(StubRepository)

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

  test "install_all raises GitCloneError when git clone fails" do
    Given "a git dep with no prepopulated source and a failing git clone"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache"))
    git_repo = Dev::Deps::GitRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: git_repo, cache: cache, project_root: dir)
    deps = [
      Dev::Deps::Dependency.new(
        name: "bad_repo", integration: :cmake, group: :app,
        version: "abc123", hash: nil,
        metadata: { "repo" => "https://example.com/bad_repo" },
      ),
    ]
    integration.stubs(:system).returns(false)

    When "installing all"
    integration.install_all(deps)

    Then
    raises Dev::Deps::CmakeIntegration::GitCloneError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises GitCheckoutError when checkout fails" do
    Given "a git dep where clone succeeds but checkout fails"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache"))
    git_repo = Dev::Deps::GitRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: git_repo, cache: cache, project_root: dir)
    deps = [
      Dev::Deps::Dependency.new(
        name: "bad_checkout", integration: :cmake, group: :app,
        version: "abc123", hash: nil,
        metadata: { "repo" => "https://example.com/bad_checkout" },
      ),
    ]
    integration.stubs(:system)
               .with("git", "clone", "--no-checkout", "-q", anything, anything)
               .returns(true)
    integration.stubs(:system)
               .with("git", "-c", "advice.detachedHead=false", "checkout", anything, chdir: anything)
               .returns(false)

    When "installing all"
    integration.install_all(deps)

    Then
    raises Dev::Deps::CmakeIntegration::GitCheckoutError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises DownloadError when curl fails" do
    Given "a URL dep with no cache and a failing download"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache"))
    url_repo = Dev::Deps::UrlRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: url_repo, cache: cache, project_root: dir)
    deps = [
      Dev::Deps::Dependency.new(
        name: "bad_url", integration: :cmake, group: :app,
        version: "1.0.0", hash: nil,
        metadata: { "url" => "https://example.com/missing.tar.gz" },
      ),
    ]
    integration.stubs(:system)
               .with("curl", "-fsSL", "-o", anything, anything)
               .returns(false)

    When "installing all"
    integration.install_all(deps)

    Then
    raises Dev::Deps::CmakeIntegration::DownloadError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises ExtractError when tar fails" do
    Given "a URL dep with a tarball that fails to extract"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache"))
    url_repo = Dev::Deps::UrlRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: url_repo, cache: cache, project_root: dir)
    deps = [
      Dev::Deps::Dependency.new(
        name: "bad_tar", integration: :cmake, group: :app,
        version: "1.0.0", hash: nil,
        metadata: { "url" => "https://example.com/bad.tar.gz" },
      ),
    ]
    # curl succeeds but tar fails
    integration.stubs(:system).with { |cmd, *_| cmd == "curl" }.returns(true)
    integration.stubs(:system).with { |cmd, *_| cmd == "tar" }.returns(false)

    When "installing all"
    integration.install_all(deps)

    Then
    raises Dev::Deps::CmakeIntegration::ExtractError

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

  test "install_all calls post_install hook after fetching" do
    Given "a dependency with a post_install hook"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    git_repo = Dev::Deps::GitRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: git_repo, cache: cache, project_root: dir)
    prepopulate_dep(dir, "mylib")
    hook_calls = []
    hook = ->(dep, root) { hook_calls << [dep.name, root.to_s] }
    deps = [
      Dev::Deps::Dependency.new(
        name: "mylib", integration: :cmake, group: :app,
        version: "sha1", hash: nil,
        metadata: { "repo" => "https://github.com/example/mylib" },
        post_install: hook,
      ),
    ]

    When "installing all"
    integration.install_all(deps)

    Then
    hook_calls.size == 1
    hook_calls[0][0] == "mylib"
    hook_calls[0][1] == dir

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all calls multiple post_install hooks in order" do
    Given "a dependency with an array of post_install hooks"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    git_repo = Dev::Deps::GitRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: git_repo, cache: cache, project_root: dir)
    prepopulate_dep(dir, "mylib")
    order = []
    hook_a = ->(_dep, _root) { order << :a }
    hook_b = ->(_dep, _root) { order << :b }
    deps = [
      Dev::Deps::Dependency.new(
        name: "mylib", integration: :cmake, group: :app,
        version: "sha1", hash: nil,
        metadata: { "repo" => "https://github.com/example/mylib" },
        post_install: [hook_a, hook_b],
      ),
    ]

    When "installing all"
    integration.install_all(deps)

    Then
    order == [:a, :b]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "post_install hook receives correct dep and root from full DSL-resolve-install pipeline" do
    Given "a DSL config with a post_install hook wired through the resolver"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    git_repo = Dev::Deps::GitRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: git_repo, cache: cache, project_root: dir)
    prepopulate_dep(dir, "googletest")

    hook_calls = []
    hook = ->(dep, root) { hook_calls << { name: dep.name, version: dep.version, root: root.to_s } }

    fetched = Dev::Deps::Dependency.new(
      name: "googletest", integration: :cmake, group: :test,
      version: "sha1", hash: nil,
      metadata: { "repo" => "https://github.com/google/googletest" },
    )
    stub_repo = StubRepository.new(deps_by_name: { "googletest" => fetched })
    resolver = Dev::Deps::Resolver.new(repositories: { cmake: stub_repo })
    declarations = [
      Dev::Deps::DependencyDeclaration.new(
        name: "googletest", integration: :cmake, group: :test,
        constraint: { "repo" => "https://github.com/google/googletest" },
        post_install: hook,
      ),
    ]

    When "resolving and installing"
    resolved = resolver.resolve(declarations)
    integration.install_all(resolved)

    Then "the hook was called with the resolved dep and project root"
    hook_calls.size == 1
    hook_calls[0][:name] == "googletest"
    hook_calls[0][:version] == "sha1"
    hook_calls[0][:root] == dir

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all skips post_install when nil" do
    Given "a dependency without a post_install hook"
    dir = Dir.mktmpdir("dev-cmake-int-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    git_repo = Dev::Deps::GitRepository.new
    integration = Dev::Deps::CmakeIntegration.new(repository: git_repo, cache: cache, project_root: dir)
    prepopulate_dep(dir, "boost")
    deps = [
      Dev::Deps::Dependency.new(
        name: "boost", integration: :cmake, group: :app,
        version: "sha1", hash: nil,
        metadata: { "repo" => "https://github.com/boost/boost" },
      ),
    ]

    When "installing all"
    integration.install_all(deps)
    cmake_content = File.read(File.join(dir, "deps.cmake"))

    Then "no error, deps.cmake still generated"
    cmake_content.include?('set(dep_boost_repo')

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
