# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/gh_repository"
require "json"

transform!(RSpock::AST::Transformation)
class Dev::Deps::GhRepositoryTest < Minitest::Test
  RELEASE_JSON = {
    "tag_name" => "5.6.1-css-83",
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
    Dev::Deps::PackageId.new(
      integration: :gh, name: "UnrealEngine", source: "satisfactorymodding/UnrealEngine",
    )
  end

  def source_id
    Dev::Deps::PackageId.new(integration: :gh, name: "UnrealEngine", source: "EpicGames/UnrealEngine")
  end

  # Stub both facts the repository gathers for a tag: the commit SHA it
  # points at and (optionally) the release it publishes.
  def stub_tag(repo, slug:, tag:, sha: "abc123sha", release: :none)
    repo.stubs(:run_gh_api)
        .with("repos/#{slug}/commits/#{tag}")
        .returns([JSON.generate({ "sha" => sha }), "", stub(success?: true)])
    release_response = if release == :none
      ["", "gh: Not Found (HTTP 404)", stub(success?: false)]
    else
      [JSON.generate(release), "", stub(success?: true)]
    end
    repo.stubs(:run_gh_api)
        .with("repos/#{slug}/releases/tags/#{tag}")
        .returns(release_response)
  end

  test "find reports the probed tag as a singleton with every release asset as facts" do
    Given "a repository with a stubbed gh api response"
    repo = Dev::Deps::GhRepository.new
    stub_tag(repo, slug: "satisfactorymodding/UnrealEngine", tag: "5.6.1-css-83",
      sha: "css83sha", release: RELEASE_JSON)

    When "finding with the tag as the probe"
    package = repo.find(prebuilt_id, probe: "5.6.1-css-83")

    Then "one version carrying the tag's facts — all assets, unselected"
    package.versions.map(&:version) == ["5.6.1-css-83"]
    version = package.version("5.6.1-css-83")
    version.digest.nil?
    version.metadata["repo"] == "satisfactorymodding/UnrealEngine"
    version.metadata["commit"] == "css83sha"
    version.metadata["assets"].map { |a| a["sha256"] } == ["aaaa1111", "bbbb2222", "cccc3333"]
  end

  test "find reports a release-less tag as a source-only version — no assets fact" do
    Given "a repository resolving a tag that publishes no release"
    repo = Dev::Deps::GhRepository.new
    stub_tag(repo, slug: "EpicGames/UnrealEngine", tag: "5.6.1-release", sha: "abc123sha")

    When "finding the tag"
    package = repo.find(source_id, probe: "5.6.1-release")

    Then "the singleton version carries the commit and no assets key"
    version = package.version("5.6.1-release")
    version.metadata["commit"] == "abc123sha"
    version.metadata["repo"] == "EpicGames/UnrealEngine"
    !version.metadata.key?("assets")
  end

  test "find claims an empty Resolved declaration set — self-contained by contract" do
    Given "a repository with a stubbed tag"
    repo = Dev::Deps::GhRepository.new
    stub_tag(repo, slug: "EpicGames/UnrealEngine", tag: "v1")

    When "finding"
    package = repo.find(source_id, probe: "v1")

    Then
    package.version("v1").declarations == Dev::Deps::Declarations::Resolved.new([])
  end

  test "find raises MissingTagError without a probe — this universe needs a coordinate" do
    Given "a repository"
    repo = Dev::Deps::GhRepository.new

    When "finding without a tag"
    repo.find(prebuilt_id)

    Then
    raises Dev::Deps::GhRepository::MissingTagError
  end

  test "find raises ReleaseNotFoundError, a PackageNotFoundError, for a missing tag" do
    Given "a gh api that 404s the commit but sees the repo"
    repo = Dev::Deps::GhRepository.new
    repo.stubs(:run_gh_api)
        .with("repos/satisfactorymodding/UnrealEngine/commits/9.9.9-css-1")
        .returns(["", "gh: Not Found (HTTP 404)", stub(success?: false)])
    repo.stubs(:run_gh_api)
        .with("repos/satisfactorymodding/UnrealEngine")
        .returns(["{}", "", stub(success?: true)])

    When "finding a nonexistent tag"
    repo.find(prebuilt_id, probe: "9.9.9-css-1")

    Then
    raises Dev::Deps::Repository::PackageNotFoundError
  end

  test "find omits sha256 for assets without an API digest" do
    Given "a release whose asset has no digest"
    repo = Dev::Deps::GhRepository.new
    release = {
      "tag_name" => "v1.0",
      "assets" => [{ "name" => "tool-Linux.tar.zst", "size" => 100, "digest" => nil }],
    }
    stub_tag(repo, slug: "satisfactorymodding/UnrealEngine", tag: "v1.0", release: release)

    When "finding the release"
    package = repo.find(prebuilt_id, probe: "v1.0")

    Then
    assets = package.version("v1.0").metadata["assets"]
    assets.size == 1
    !assets[0].key?("sha256")
  end

  test "find raises RepoAccessError when the repo itself is invisible" do
    Given "a 404 on both the commit and the repo"
    repo = Dev::Deps::GhRepository.new
    repo.stubs(:run_gh_api).returns(["", "gh: Not Found (HTTP 404)", stub(success?: false)])

    When "finding in an inaccessible repo"
    repo.find(prebuilt_id, probe: "5.6.1-css-83")

    Then
    raises Dev::Deps::GhRepository::RepoAccessError
  end

  test "find raises AuthenticationError when gh is not logged in" do
    Given "gh demanding authentication"
    repo = Dev::Deps::GhRepository.new
    err = "To get started with GitHub CLI, please run: gh auth login"
    repo.stubs(:run_gh_api).returns(["", err, stub(success?: false)])

    When "finding without authentication"
    repo.find(prebuilt_id, probe: "5.6.1-css-83")

    Then
    raises Dev::Deps::GhRepository::AuthenticationError
  end

  test "find raises ApiError for other gh failures" do
    Given "a server error from gh"
    repo = Dev::Deps::GhRepository.new
    repo.stubs(:run_gh_api).returns(["", "gh: Internal Server Error (HTTP 500)", stub(success?: false)])

    When "finding during an API outage"
    repo.find(prebuilt_id, probe: "5.6.1-css-83")

    Then
    raises Dev::Deps::GhRepository::ApiError
  end

  test "find raises GhMissingError when the gh CLI is not installed" do
    Given "no gh binary on PATH"
    repo = Dev::Deps::GhRepository.new
    Open3.stubs(:capture3).raises(Errno::ENOENT.new("gh"))

    When "finding without gh installed"
    repo.find(prebuilt_id, probe: "5.6.1-css-83")

    Then
    raises Dev::Deps::GhRepository::GhMissingError
  end

  test "find raises ApiError when the release fetch fails for a non-404 reason" do
    Given "a resolvable commit but a flaky release endpoint"
    repo = Dev::Deps::GhRepository.new
    repo.stubs(:run_gh_api)
        .with("repos/EpicGames/UnrealEngine/commits/v1")
        .returns([JSON.generate({ "sha" => "abc" }), "", stub(success?: true)])
    repo.stubs(:run_gh_api)
        .with("repos/EpicGames/UnrealEngine/releases/tags/v1")
        .returns(["", "gh: Internal Server Error (HTTP 500)", stub(success?: false)])

    When "finding"
    repo.find(source_id, probe: "v1")

    Then
    raises Dev::Deps::GhRepository::ApiError
  end
end
