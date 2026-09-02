# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/git_repository"
require "dev/deps/cache"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::GitRepositoryTest < Minitest::Test
  test "find reports the declared tag's SHA as a singleton universe" do
    Given "a remote resolving the tag via ls-remote"
    repo = Dev::Deps::GitRepository.new
    resolved_sha = "abcdef1234567890abcdef1234567890abcdef12"
    Open3.stubs(:capture3)
         .with("git", "ls-remote", "--tags", "https://github.com/google/googletest", "v1.17.0")
         .returns(["#{resolved_sha}\trefs/tags/v1.17.0\n", "", stub(success?: true)])

    When "finding with the tag as locator"
    package = repo.find(
      Dev::Deps::PackageId.new(
        integration: :cmake, name: "googletest", source: "https://github.com/google/googletest",
      ),
      filter: { "tag" => "v1.17.0" },
    )

    Then "one version: the SHA, no digest (SHAs are identifiers, not integrity)"
    package.versions.map(&:version) == [resolved_sha]
    package.version(resolved_sha).digest.nil?
    package.version(resolved_sha).metadata == { "repo" => "https://github.com/google/googletest" }
  end

  test "find passes a 40-char commit SHA through without network calls" do
    Given "a commit-pinned declaration"
    repo = Dev::Deps::GitRepository.new
    sha = "ee3042f8b0279856061f91069a487e4ed6f69475"

    When "finding with the commit as locator"
    package = repo.find(
      Dev::Deps::PackageId.new(
        integration: :cmake, name: "entityx", source: "https://github.com/alecthomas/entityx",
      ),
      filter: { "commit" => sha },
    )

    Then
    package.versions.map(&:version) == [sha]
  end

  test "find raises RefResolutionError, a PackageNotFoundError, for a bad ref" do
    Given "a remote that knows no such ref"
    repo = Dev::Deps::GitRepository.new
    Open3.stubs(:capture3).returns(["", "", stub(success?: true)])

    When "finding with an unresolvable tag"
    repo.find(
      Dev::Deps::PackageId.new(integration: :cmake, name: "ghost", source: "https://example.com/ghost"),
      filter: { "tag" => "v0.0.0" },
    )

    Then
    raises Dev::Deps::Repository::PackageNotFoundError
  end

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

  test "fetch raises RefResolutionError for unresolvable ref" do
    Given "a tag that does not exist on the remote"
    repo = Dev::Deps::GitRepository.new
    failed_status = stub(success?: false)
    Open3.stubs(:capture3)
         .with("git", "ls-remote", "--tags", "https://github.com/example/repo", "nonexistent-tag")
         .returns(["", "", failed_status])
    Open3.stubs(:capture3)
         .with("git", "ls-remote", "https://github.com/example/repo", "refs/heads/nonexistent-tag")
         .returns(["", "", failed_status])

    When "fetching by unresolvable tag"
    repo.fetch(
      "name" => "bad",
      "repo" => "https://github.com/example/repo",
      "tag" => "nonexistent-tag",
      "integration" => "cmake",
      "group" => "app",
    )

    Then
    raises Dev::Deps::GitRepository::RefResolutionError
  end
end
