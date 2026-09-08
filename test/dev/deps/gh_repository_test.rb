# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/gh_repository"
require "json"

transform!(RSpock::AST::Transformation)
class Dev::Deps::GhRepositoryTest < Minitest::Test
  SLUG = "satisfactorymodding/UnrealEngine"

  RELEASE_JSON = {
    "tag_name" => "5.6.1-css-83",
    "draft" => false,
    "assets" => [
      {
        "name" => "UnrealEngine-CSS-Editor-Linux.tar.zst.00",
        "size" => 2_147_483_648,
        "digest" => "sha256:aaaa1111",
      },
      {
        "name" => "UnrealEngine-CSS-Editor-Linux.tar.zst.01",
        "size" => 1_820_000_000,
        "digest" => "sha256:bbbb2222",
      },
      {
        "name" => "UnrealEngine-CSS-Editor-Win64.exe",
        "size" => 20_000_000,
        "digest" => "sha256:cccc3333",
      },
    ],
  }.freeze

  def prebuilt_id
    Dev::Deps::PackageId.new(integration: :gh, name: "UnrealEngine", source: SLUG)
  end

  def tag_json(name, sha)
    { "name" => name, "commit" => { "sha" => sha } }
  end

  # Stub the two list endpoints the repository enumerates (single page each).
  def stub_universe(repo, slug: SLUG, releases: [], tags: [])
    repo.stubs(:run_gh_api)
        .with("repos/#{slug}/releases?per_page=100&page=1")
        .returns([JSON.generate(releases), "", stub(success?: true)])
    repo.stubs(:run_gh_api)
        .with("repos/#{slug}/tags?per_page=100&page=1")
        .returns([JSON.generate(tags), "", stub(success?: true)])
  end

  test "find enumerates tags and releases into one facts-complete universe" do
    Given "a repo with a released tag and a source-only tag"
    repo = Dev::Deps::GhRepository.new
    stub_universe(repo,
      releases: [RELEASE_JSON],
      tags: [tag_json("5.6.1-css-83", "css83sha"), tag_json("5.6.1-release", "relsha")])

    When "finding"
    package = repo.find(prebuilt_id)

    Then "the released tag carries commit + all assets; the bare tag just its commit"
    package.versions.map(&:version).sort == ["5.6.1-css-83", "5.6.1-release"]
    released = package.version("5.6.1-css-83")
    released.digest.nil?
    released.metadata["repo"] == SLUG
    released.metadata["commit"] == "css83sha"
    released.metadata["assets"].map { |a| a["sha256"] } == ["aaaa1111", "bbbb2222", "cccc3333"]
    source_only = package.version("5.6.1-release")
    source_only.metadata["commit"] == "relsha"
    !source_only.metadata.key?("assets")
  end

  test "find orders releases last, newest at the end — the unconstrained pick" do
    Given "two releases (API lists newest first) and a bare tag"
    repo = Dev::Deps::GhRepository.new
    stub_universe(repo,
      releases: [
        { "tag_name" => "v2.0", "draft" => false, "assets" => [] },
        { "tag_name" => "v1.0", "draft" => false, "assets" => [] },
      ],
      tags: [tag_json("v2.0", "sha2"), tag_json("v1.0", "sha1"), tag_json("wip", "sha3")])

    When "finding"
    package = repo.find(prebuilt_id)

    Then "tag-only first, then releases oldest to newest — last wins unconstrained"
    package.versions.map(&:version) == ["wip", "v1.0", "v2.0"]
  end

  test "find skips draft releases — no tag exists until publish" do
    Given "a draft release alongside a published one"
    repo = Dev::Deps::GhRepository.new
    stub_universe(repo,
      releases: [
        { "tag_name" => "v2.0-draft", "draft" => true, "assets" => [] },
        { "tag_name" => "v1.0", "draft" => false, "assets" => [] },
      ],
      tags: [tag_json("v1.0", "sha1")])

    When "finding"
    package = repo.find(prebuilt_id)

    Then
    package.versions.map(&:version) == ["v1.0"]
  end

  test "find paginates list endpoints to exhaustion" do
    Given "a repo with 100 tags on page one and 1 on page two"
    repo = Dev::Deps::GhRepository.new
    page_one = (1..100).map { |i| tag_json("v#{i}", "sha#{i}") }
    page_two = [tag_json("v101", "sha101")]
    repo.stubs(:run_gh_api)
        .with("repos/#{SLUG}/releases?per_page=100&page=1")
        .returns([JSON.generate([]), "", stub(success?: true)])
    repo.stubs(:run_gh_api)
        .with("repos/#{SLUG}/tags?per_page=100&page=1")
        .returns([JSON.generate(page_one), "", stub(success?: true)])
    repo.stubs(:run_gh_api)
        .with("repos/#{SLUG}/tags?per_page=100&page=2")
        .returns([JSON.generate(page_two), "", stub(success?: true)])

    When "finding"
    package = repo.find(prebuilt_id)

    Then
    package.versions.size == 101
  end

  test "find claims an empty Resolved declaration set — self-contained by contract" do
    Given "a repo with one tag"
    repo = Dev::Deps::GhRepository.new
    stub_universe(repo, tags: [tag_json("v1", "sha")])

    When "finding"
    package = repo.find(prebuilt_id)

    Then
    package.version("v1").declarations == Dev::Deps::Declarations::Resolved.new([])
  end

  test "find raises PackageNotFoundError for a repo with no tags or releases" do
    Given "an empty universe"
    repo = Dev::Deps::GhRepository.new
    stub_universe(repo)

    When "finding"
    repo.find(prebuilt_id)

    Then
    raises Dev::Deps::Repository::PackageNotFoundError
  end

  test "find omits sha256 for assets without an API digest" do
    Given "a release whose asset has no digest"
    repo = Dev::Deps::GhRepository.new
    release = {
      "tag_name" => "v1.0",
      "draft" => false,
      "assets" => [{ "name" => "tool-Linux.tar.zst", "size" => 100, "digest" => nil }],
    }
    stub_universe(repo, releases: [release], tags: [tag_json("v1.0", "sha")])

    When "finding"
    package = repo.find(prebuilt_id)

    Then
    assets = package.version("v1.0").metadata["assets"]
    assets.size == 1
    !assets[0].key?("sha256")
  end

  test "find raises RepoAccessError when the repo is invisible — list endpoints 404 only then" do
    Given "a 404 on the releases list"
    repo = Dev::Deps::GhRepository.new
    repo.stubs(:run_gh_api).returns(["", "gh: Not Found (HTTP 404)", stub(success?: false)])

    When "finding in an inaccessible repo"
    repo.find(prebuilt_id)

    Then
    raises Dev::Deps::GhRepository::RepoAccessError
  end

  test "find raises AuthenticationError when gh is not logged in" do
    Given "gh demanding authentication"
    repo = Dev::Deps::GhRepository.new
    err = "To get started with GitHub CLI, please run: gh auth login"
    repo.stubs(:run_gh_api).returns(["", err, stub(success?: false)])

    When "finding without authentication"
    repo.find(prebuilt_id)

    Then
    raises Dev::Deps::GhRepository::AuthenticationError
  end

  test "find raises ApiError for other gh failures" do
    Given "a server error from gh"
    repo = Dev::Deps::GhRepository.new
    repo.stubs(:run_gh_api).returns(["", "gh: Internal Server Error (HTTP 500)", stub(success?: false)])

    When "finding during an API outage"
    repo.find(prebuilt_id)

    Then
    raises Dev::Deps::GhRepository::ApiError
  end

  test "find raises GhMissingError when the gh CLI is not installed" do
    Given "no gh binary on PATH"
    repo = Dev::Deps::GhRepository.new
    Open3.stubs(:capture3).raises(Errno::ENOENT.new("gh"))

    When "finding without gh installed"
    repo.find(prebuilt_id)

    Then
    raises Dev::Deps::GhRepository::GhMissingError
  end
end
