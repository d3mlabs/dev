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

  def prebuilt_filter(overrides = {})
    {
      "tag" => "5.6.1-css-83",
      "assets" => "UnrealEngine-CSS-Editor-Linux.tar.zst.*",
      "install_dir" => "~/.dev/engines/unreal-engine-css",
    }.merge(overrides)
  end

  def source_id
    Dev::Deps::PackageId.new(integration: :gh, name: "UnrealEngine", source: "EpicGames/UnrealEngine")
  end

  test "find reports the declared tag's release as a singleton universe" do
    Given "a repository with a stubbed gh api response"
    repo = Dev::Deps::GhRepository.new
    repo.stubs(:run_gh_api)
        .with("repos/satisfactorymodding/UnrealEngine/releases/tags/5.6.1-css-83")
        .returns([JSON.generate(RELEASE_JSON), "", stub(success?: true)])

    When "finding with the tag and asset glob as locator"
    package = repo.find(
      Dev::Deps::PackageId.new(
        integration: :gh, name: "UnrealEngine", source: "satisfactorymodding/UnrealEngine",
      ),
      filter: {
        "tag" => "5.6.1-css-83",
        "assets" => "UnrealEngine-CSS-Editor-Linux.tar.zst.*",
        "install_dir" => "~/.dev/engines/unreal-engine-css",
      },
    )

    Then "one version carrying the prebuilt install facts"
    package.versions.map(&:version) == ["5.6.1-css-83"]
    version = package.version("5.6.1-css-83")
    version.digest.nil?
    version.metadata["repo"] == "satisfactorymodding/UnrealEngine"
    version.metadata["asset_pattern"] == "UnrealEngine-CSS-Editor-Linux.tar.zst.*"
    version.metadata["install_dir"] == "~/.dev/engines/unreal-engine-css"
    version.metadata["assets"].map { |a| a["sha256"] } == ["aaaa1111", "bbbb2222"]
  end

  test "find pins the source shape to the tag with its commit SHA" do
    Given "a repository resolving a tag to a commit"
    repo = Dev::Deps::GhRepository.new
    repo.stubs(:run_gh_api)
        .with("repos/EpicGames/UnrealEngine/commits/5.6.1-release")
        .returns([JSON.generate({ "sha" => "abc123sha" }), "", stub(success?: true)])

    When "finding with a build recipe instead of assets"
    package = repo.find(
      Dev::Deps::PackageId.new(integration: :gh, name: "UnrealEngine", source: "EpicGames/UnrealEngine"),
      filter: { "tag" => "5.6.1-release", "build" => "make", "install_dir" => "~/.dev/engines/ue" },
    )

    Then "the singleton version carries the source install facts"
    version = package.version("5.6.1-release")
    version.metadata["commit"] == "abc123sha"
    version.metadata["build"] == "make"
    version.metadata["repo"] == "EpicGames/UnrealEngine"
  end

  test "find raises ReleaseNotFoundError, a PackageNotFoundError, for a missing tag" do
    Given "a gh api that 404s the release but sees the repo"
    repo = Dev::Deps::GhRepository.new
    repo.stubs(:run_gh_api)
        .with("repos/satisfactorymodding/UnrealEngine/releases/tags/9.9.9-css-1")
        .returns(["", "gh: Not Found (HTTP 404)", stub(success?: false)])
    repo.stubs(:run_gh_api)
        .with("repos/satisfactorymodding/UnrealEngine")
        .returns(["{}", "", stub(success?: true)])

    When "finding a nonexistent tag"
    repo.find(
      Dev::Deps::PackageId.new(
        integration: :gh, name: "UnrealEngine", source: "satisfactorymodding/UnrealEngine",
      ),
      filter: { "tag" => "9.9.9-css-1", "assets" => "*.tar.zst.*" },
    )

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
    repo.stubs(:run_gh_api).returns([JSON.generate(release), "", stub(success?: true)])

    When "finding the release"
    package = repo.find(prebuilt_id, filter: prebuilt_filter("assets" => "tool-Linux.tar.zst", "tag" => "v1.0"))

    Then
    assets = package.version("v1.0").metadata["assets"]
    assets.size == 1
    !assets[0].key?("sha256")
  end

  test "find raises NoMatchingAssetsError when the pattern matches nothing" do
    Given "a release without assets matching the pattern"
    repo = Dev::Deps::GhRepository.new
    repo.stubs(:run_gh_api).returns([JSON.generate(RELEASE_JSON), "", stub(success?: true)])

    When "finding with a non-matching pattern"
    repo.find(prebuilt_id, filter: prebuilt_filter("assets" => "*.7z.*"))

    Then
    raises Dev::Deps::GhRepository::NoMatchingAssetsError
  end

  test "find raises RepoAccessError when the repo itself is invisible" do
    Given "a 404 on both the release and the repo"
    repo = Dev::Deps::GhRepository.new
    repo.stubs(:run_gh_api).returns(["", "gh: Not Found (HTTP 404)", stub(success?: false)])

    When "finding in an inaccessible repo"
    repo.find(prebuilt_id, filter: prebuilt_filter)

    Then
    raises Dev::Deps::GhRepository::RepoAccessError
  end

  test "find raises AuthenticationError when gh is not logged in" do
    Given "gh demanding authentication"
    repo = Dev::Deps::GhRepository.new
    err = "To get started with GitHub CLI, please run: gh auth login"
    repo.stubs(:run_gh_api).returns(["", err, stub(success?: false)])

    When "finding without authentication"
    repo.find(prebuilt_id, filter: prebuilt_filter)

    Then
    raises Dev::Deps::GhRepository::AuthenticationError
  end

  test "find raises ApiError for other gh failures" do
    Given "a server error from gh"
    repo = Dev::Deps::GhRepository.new
    repo.stubs(:run_gh_api).returns(["", "gh: Internal Server Error (HTTP 500)", stub(success?: false)])

    When "finding during an API outage"
    repo.find(prebuilt_id, filter: prebuilt_filter)

    Then
    raises Dev::Deps::GhRepository::ApiError
  end

  test "find raises GhMissingError when the gh CLI is not installed" do
    Given "no gh binary on PATH"
    repo = Dev::Deps::GhRepository.new
    Open3.stubs(:capture3).raises(Errno::ENOENT.new("gh"))

    When "finding without gh installed"
    repo.find(prebuilt_id, filter: prebuilt_filter)

    Then
    raises Dev::Deps::GhRepository::GhMissingError
  end

  test "find source raises ReleaseNotFoundError when the tag is missing but repo is visible" do
    Given "a 404 on the commit and a visible repo"
    repo = Dev::Deps::GhRepository.new
    repo.stubs(:run_gh_api)
        .with("repos/EpicGames/UnrealEngine/commits/9.9.9")
        .returns(["", "gh: Not Found (HTTP 404)", stub(success?: false)])
    repo.stubs(:run_gh_api)
        .with("repos/EpicGames/UnrealEngine")
        .returns([JSON.generate({ "full_name" => "EpicGames/UnrealEngine" }), "", stub(success?: true)])

    When "finding a nonexistent tag"
    repo.find(source_id, filter: { "tag" => "9.9.9", "build" => "make" })

    Then
    raises Dev::Deps::GhRepository::ReleaseNotFoundError
  end

  test "find source raises RepoAccessError when the repo is invisible (account not linked)" do
    Given "a 404 on both the commit and the repo"
    repo = Dev::Deps::GhRepository.new
    repo.stubs(:run_gh_api).returns(["", "gh: Not Found (HTTP 404)", stub(success?: false)])

    When "finding in an inaccessible repo"
    repo.find(source_id, filter: { "tag" => "5.6.1-release", "build" => "make" })

    Then
    raises Dev::Deps::GhRepository::RepoAccessError
  end
end
