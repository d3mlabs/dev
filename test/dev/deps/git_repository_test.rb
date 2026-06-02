# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/git_repository"
require "dev/deps/cache"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::GitRepositoryTest < Minitest::Test
  test "resolve passes through a 40-char hex commit SHA as-is" do
    Given
    dir = Dir.mktmpdir("dev-git-repo-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    repo = Dev::Deps::GitRepository.new

    When
    pin = repo.resolve(
      "entityx",
      { "repo" => "https://github.com/alecthomas/entityx", "commit" => "ee3042f8b0279856061f91069a487e4ed6f69475",
        "integration" => "cmake", "group" => "app" },
      cache: cache,
    )

    Then
    pin.name == "entityx"
    pin.version == "ee3042f8b0279856061f91069a487e4ed6f69475"
    pin.integration == :cmake
    pin.group == :app

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "resolve calls git ls-remote for a tag" do
    Given
    dir = Dir.mktmpdir("dev-git-repo-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    repo = Dev::Deps::GitRepository.new
    # Stub the shell call to git ls-remote
    resolved_sha = "abcdef1234567890abcdef1234567890abcdef12"
    Open3.stubs(:capture3)
         .with("git", "ls-remote", "--tags", "https://github.com/google/googletest", "v1.17.0")
         .returns(["#{resolved_sha}\trefs/tags/v1.17.0\n", "", stub(success?: true)])

    When
    pin = repo.resolve(
      "googletest",
      { "repo" => "https://github.com/google/googletest", "tag" => "v1.17.0",
        "integration" => "cmake", "group" => "test" },
      cache: cache,
    )

    Then
    pin.name == "googletest"
    pin.version == resolved_sha
    pin.integration == :cmake
    pin.group == :test

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "dependencies returns empty array" do
    Given
    repo = Dev::Deps::GitRepository.new
    pin = Dev::Deps::Pin.new(name: "boost", integration: :cmake, group: :app,
                              version: "abc123", hash: nil, metadata: {})

    Expect
    repo.dependencies(pin) == []
  end
end
