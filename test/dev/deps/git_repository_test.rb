# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/git_repository"
require "dev/deps/cache"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::GitRepositoryTest < Minitest::Test
  test "fetch passes through a 40-char hex commit SHA as-is" do
    Given "a commit SHA identifier"
    repo = Dev::Deps::GitRepository.new

    When "fetching by commit"
    dep = repo.fetch(
      "name" => "entityx",
      "repo" => "https://github.com/alecthomas/entityx",
      "commit" => "ee3042f8b0279856061f91069a487e4ed6f69475",
      "integration" => "cmake",
      "group" => "app",
    )

    Then
    dep.name == "entityx"
    dep.version == "ee3042f8b0279856061f91069a487e4ed6f69475"
    dep.integration == :cmake
    dep.group == :app
  end

  test "fetch calls git ls-remote for a tag" do
    Given "a tag identifier"
    repo = Dev::Deps::GitRepository.new
    resolved_sha = "abcdef1234567890abcdef1234567890abcdef12"
    Open3.stubs(:capture3)
         .with("git", "ls-remote", "--tags", "https://github.com/google/googletest", "v1.17.0")
         .returns(["#{resolved_sha}\trefs/tags/v1.17.0\n", "", stub(success?: true)])

    When "fetching by tag"
    dep = repo.fetch(
      "name" => "googletest",
      "repo" => "https://github.com/google/googletest",
      "tag" => "v1.17.0",
      "integration" => "cmake",
      "group" => "test",
    )

    Then
    dep.name == "googletest"
    dep.version == resolved_sha
    dep.integration == :cmake
    dep.group == :test
  end
end
