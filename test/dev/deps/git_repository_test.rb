# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/git_repository"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::GitRepositoryTest < Minitest::Test
  REMOTE = "https://github.com/google/googletest"

  def id(name: "googletest", source: REMOTE)
    Dev::Deps::PackageId.new(integration: :cmake, name: name, source: source)
  end

  def stub_ls_remote(output, success: true)
    Open3.stubs(:capture3)
         .with("git", "ls-remote", "--tags", "--heads", REMOTE)
         .returns([output, "", stub(success?: success)])
  end

  test "find enumerates every tag and branch head as SHA-versioned facts" do
    Given "a remote listing tags and heads in one ls-remote call"
    repo = Dev::Deps::GitRepository.new
    stub_ls_remote(<<~LS)
      1111111111111111111111111111111111111111\trefs/heads/main
      2222222222222222222222222222222222222222\trefs/tags/v1.16.0
      3333333333333333333333333333333333333333\trefs/tags/v1.17.0
    LS

    When "finding"
    package = repo.find(id)

    Then "one version per ref: the SHA, no digest, the ref riding as a fact"
    package.versions.size == 3
    package.version("3" * 40).metadata == { "repo" => REMOTE, "ref" => "v1.17.0" }
    package.version("1" * 40).metadata == { "repo" => REMOTE, "ref" => "main" }
    package.versions.all? { |v| v.digest.nil? }
    package.versions.all? { |v| v.declarations == Dev::Deps::Declarations::Resolved.new([]) }
  end

  test "find prefers the peeled SHA for annotated tags — the commit a checkout materializes" do
    Given "an annotated tag listing its tag object and its peeled commit"
    repo = Dev::Deps::GitRepository.new
    stub_ls_remote(<<~LS)
      aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/tags/v1.17.0
      bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\trefs/tags/v1.17.0^{}
    LS

    When "finding"
    package = repo.find(id)

    Then "the peeled commit SHA wins, as one version"
    package.versions.map(&:version) == ["b" * 40]
  end

  test "find ignores the probe — refs are enumerable" do
    Given "a remote with one tag"
    repo = Dev::Deps::GitRepository.new
    stub_ls_remote("#{"1" * 40}\trefs/tags/v1.0.0\n")

    When "finding with a leftover probe"
    package = repo.find(id, probe: "v9.9.9")

    Then "the universe is whatever the remote lists"
    package.versions.map(&:version) == ["1" * 40]
  end

  test "find raises RefResolutionError when ls-remote fails" do
    Given "an unreachable remote"
    repo = Dev::Deps::GitRepository.new
    stub_ls_remote("", success: false)

    When "finding"
    repo.find(id)

    Then
    raises Dev::Deps::GitRepository::RefResolutionError
  end

  test "find raises RefResolutionError when the remote lists no refs" do
    Given "an empty remote"
    repo = Dev::Deps::GitRepository.new
    stub_ls_remote("")

    When "finding"
    repo.find(id)

    Then
    raises Dev::Deps::Repository::PackageNotFoundError
  end

  test "at lifts a commit SHA purely — no network, the SHA is the version" do
    Given "a commit address"
    repo = Dev::Deps::GitRepository.new
    sha = "ee3042f8b0279856061f91069a487e4ed6f69475"
    Open3.expects(:capture3).never

    When "lifting"
    version = repo.at(id(name: "opencell", source: "https://github.com/d3mlabs/opencell"), sha)

    Then "the address is trusted at resolve; existence surfaces at fetch"
    version.version == sha
    version.digest.nil?
    version.metadata == { "repo" => "https://github.com/d3mlabs/opencell" }
    version.declarations == Dev::Deps::Declarations::Resolved.new([])
  end
end
