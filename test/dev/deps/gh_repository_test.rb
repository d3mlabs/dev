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

  def fetch_id(overrides = {})
    {
      "name" => "UnrealEngine",
      "integration" => "gh",
      "group" => "build",
      "repo" => "satisfactorymodding/UnrealEngine",
      "tag" => "5.6.1-css-83",
      "assets" => "UnrealEngine-CSS-Editor-Linux.tar.zst.*",
      "install_dir" => "~/.dev/engines/unreal-engine-css",
    }.merge(overrides)
  end

  test "fetch resolves release to tag, matching assets, and digests" do
    Given "a repository with a stubbed gh api response"
    repo = Dev::Deps::GhRepository.new
    repo.stubs(:run_gh_api)
        .with("repos/satisfactorymodding/UnrealEngine/releases/tags/5.6.1-css-83")
        .returns([JSON.generate(RELEASE_JSON), "", stub(success?: true)])

    When "fetching the dependency"
    dep = repo.fetch(fetch_id)

    Then
    dep.name == "UnrealEngine"
    dep.integration == :gh
    dep.group == :build
    dep.version == "5.6.1-css-83"
    dep.hash.nil?
    dep.metadata["repo"] == "satisfactorymodding/UnrealEngine"
    dep.metadata["asset_pattern"] == "UnrealEngine-CSS-Editor-Linux.tar.zst.*"
    dep.metadata["install_dir"] == "~/.dev/engines/unreal-engine-css"
    dep.metadata["assets"].size == 2
    dep.metadata["assets"][0]["name"] == "UnrealEngine-CSS-Editor-Linux.tar.zst.00"
    dep.metadata["assets"][0]["size"] == 2_147_483_648
    dep.metadata["assets"][0]["sha256"] == "aaaa1111"
    dep.metadata["assets"][1]["sha256"] == "bbbb2222"
  end

  test "fetch omits sha256 for assets without an API digest" do
    Given "a release whose asset has no digest"
    repo = Dev::Deps::GhRepository.new
    release = {
      "tag_name" => "v1.0",
      "assets" => [{ "name" => "tool-Linux.tar.zst", "size" => 100, "digest" => nil }],
    }
    repo.stubs(:run_gh_api).returns([JSON.generate(release), "", stub(success?: true)])

    When "fetching the dependency"
    dep = repo.fetch(fetch_id("assets" => "tool-Linux.tar.zst"))

    Then
    dep.metadata["assets"].size == 1
    !dep.metadata["assets"][0].key?("sha256")
  end

  test "fetch raises NoMatchingAssetsError when pattern matches nothing" do
    Given "a release without assets matching the pattern"
    repo = Dev::Deps::GhRepository.new
    repo.stubs(:run_gh_api).returns([JSON.generate(RELEASE_JSON), "", stub(success?: true)])

    When "fetching with a non-matching pattern"
    repo.fetch(fetch_id("assets" => "*.7z.*"))

    Then
    raises Dev::Deps::GhRepository::NoMatchingAssetsError
  end

  test "fetch raises ReleaseNotFoundError when tag is missing but repo is visible" do
    Given "a 404 on the release and a visible repo"
    repo = Dev::Deps::GhRepository.new
    repo.stubs(:run_gh_api)
        .with("repos/satisfactorymodding/UnrealEngine/releases/tags/9.9.9-css-1")
        .returns(["", "gh: Not Found (HTTP 404)", stub(success?: false)])
    repo.stubs(:run_gh_api)
        .with("repos/satisfactorymodding/UnrealEngine")
        .returns([JSON.generate({ "full_name" => "satisfactorymodding/UnrealEngine" }), "", stub(success?: true)])

    When "fetching a nonexistent tag"
    repo.fetch(fetch_id("tag" => "9.9.9-css-1"))

    Then
    raises Dev::Deps::GhRepository::ReleaseNotFoundError
  end

  test "fetch raises RepoAccessError when the repo itself is invisible" do
    Given "a 404 on both the release and the repo"
    repo = Dev::Deps::GhRepository.new
    repo.stubs(:run_gh_api).returns(["", "gh: Not Found (HTTP 404)", stub(success?: false)])

    When "fetching from an inaccessible repo"
    repo.fetch(fetch_id)

    Then
    raises Dev::Deps::GhRepository::RepoAccessError
  end

  test "fetch raises AuthenticationError when gh is not logged in" do
    Given "gh demanding authentication"
    repo = Dev::Deps::GhRepository.new
    err = "To get started with GitHub CLI, please run: gh auth login"
    repo.stubs(:run_gh_api).returns(["", err, stub(success?: false)])

    When "fetching without authentication"
    repo.fetch(fetch_id)

    Then
    raises Dev::Deps::GhRepository::AuthenticationError
  end

  test "fetch raises ApiError for other gh failures" do
    Given "a server error from gh"
    repo = Dev::Deps::GhRepository.new
    repo.stubs(:run_gh_api).returns(["", "gh: Internal Server Error (HTTP 500)", stub(success?: false)])

    When "fetching during an API outage"
    repo.fetch(fetch_id)

    Then
    raises Dev::Deps::GhRepository::ApiError
  end

  test "fetch raises GhMissingError when the gh CLI is not installed" do
    Given "no gh binary on PATH"
    repo = Dev::Deps::GhRepository.new
    Open3.stubs(:capture3).raises(Errno::ENOENT.new("gh"))

    When "fetching without gh installed"
    repo.fetch(fetch_id)

    Then
    raises Dev::Deps::GhRepository::GhMissingError
  end

  def source_id(overrides = {})
    {
      "name" => "UnrealEngine",
      "integration" => "gh",
      "group" => "game",
      "repo" => "EpicGames/UnrealEngine",
      "tag" => "5.6.1-release",
      "build" => "bin/build-ue.sh",
      "install_dir" => "~/.dev/engines/ue5",
    }.merge(overrides)
  end

  test "fetch resolves a build-from-source dep to the tag's commit SHA and build recipe" do
    Given "a repository whose commit lookup is stubbed"
    repo = Dev::Deps::GhRepository.new
    repo.stubs(:run_gh_api)
        .with("repos/EpicGames/UnrealEngine/commits/5.6.1-release")
        .returns([JSON.generate({ "sha" => "6978b63c" }), "", stub(success?: true)])

    When "fetching the source dependency"
    dep = repo.fetch(source_id)

    Then
    dep.name == "UnrealEngine"
    dep.version == "5.6.1-release"
    dep.metadata["repo"] == "EpicGames/UnrealEngine"
    dep.metadata["install_dir"] == "~/.dev/engines/ue5"
    dep.metadata["build"] == "bin/build-ue.sh"
    dep.metadata["commit"] == "6978b63c"
    !dep.metadata.key?("assets")
  end

  test "fetch source raises ReleaseNotFoundError when the tag is missing but repo is visible" do
    Given "a 404 on the commit and a visible repo"
    repo = Dev::Deps::GhRepository.new
    repo.stubs(:run_gh_api)
        .with("repos/EpicGames/UnrealEngine/commits/9.9.9")
        .returns(["", "gh: Not Found (HTTP 404)", stub(success?: false)])
    repo.stubs(:run_gh_api)
        .with("repos/EpicGames/UnrealEngine")
        .returns([JSON.generate({ "full_name" => "EpicGames/UnrealEngine" }), "", stub(success?: true)])

    When "fetching a nonexistent tag"
    repo.fetch(source_id("tag" => "9.9.9"))

    Then
    raises Dev::Deps::GhRepository::ReleaseNotFoundError
  end

  test "fetch source raises RepoAccessError when the repo is invisible (account not linked)" do
    Given "a 404 on both the commit and the repo"
    repo = Dev::Deps::GhRepository.new
    repo.stubs(:run_gh_api).returns(["", "gh: Not Found (HTTP 404)", stub(success?: false)])

    When "fetching from an inaccessible repo"
    repo.fetch(source_id)

    Then
    raises Dev::Deps::GhRepository::RepoAccessError
  end
end
