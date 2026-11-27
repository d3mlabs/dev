# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/gh_repository"
require "json"

# GhRepository is the adapter over the gh CLI, so the `gh api` calls it makes
# are its contract and each answer is a real capture3 triple: how it reads
# the status and the stdout/stderr is the behaviour under test.
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

  # The two list endpoints the repository enumerates, one page each. An
  # empty releases list is cross-checked against /releases/latest, so a
  # tag-only universe also answers that with the 404 a release-less repo gives.
  def releases_path(slug: SLUG, page: 1)
    "repos/#{slug}/releases?per_page=100&page=#{page}"
  end

  def tags_path(slug: SLUG, page: 1)
    "repos/#{slug}/tags?per_page=100&page=#{page}"
  end

  def latest_release_path(slug: SLUG)
    "repos/#{slug}/releases/latest"
  end

  def gh_ok(payload)
    [JSON.generate(payload), "", exit_status(0)]
  end

  def gh_failure(err)
    ["", err, exit_status(1)]
  end

  def gh_not_found
    gh_failure("gh: Not Found (HTTP 404)")
  end

  test "find enumerates tags and releases into one facts-complete universe" do
    Given "a repo with a released tag and a source-only tag"
    repo = Dev::Deps::GhRepository.new

    When "finding"
    package = repo.find(prebuilt_id)

    Then "the released tag carries commit + all assets; the bare tag just its commit"
    _ * Open3.capture3("gh", "api", releases_path) >> gh_ok([RELEASE_JSON])
    _ * Open3.capture3("gh", "api", tags_path) >> gh_ok([tag_json("5.6.1-css-83", "css83sha"), tag_json("5.6.1-release", "relsha")])
    package.versions.map(&:version).sort == ["5.6.1-css-83", "5.6.1-release"]
    released = package.version("5.6.1-css-83")
    released.digest.nil?
    released.metadata["repo"] == SLUG
    released.metadata["commit"] == "css83sha"
    released.source == "css83sha"
    released.metadata["assets"].map { |a| a["sha256"] } == ["aaaa1111", "bbbb2222", "cccc3333"]
    source_only = package.version("5.6.1-release")
    source_only.metadata["commit"] == "relsha"
    !source_only.metadata.key?("assets")
  end

  test "find orders releases last, newest at the end — the unconstrained pick" do
    Given "two releases (API lists newest first) and a bare tag"
    repo = Dev::Deps::GhRepository.new
    releases = [
      { "tag_name" => "v2.0", "draft" => false, "assets" => [] },
      { "tag_name" => "v1.0", "draft" => false, "assets" => [] },
    ]

    When "finding"
    package = repo.find(prebuilt_id)

    Then "tag-only first, then releases oldest to newest — last wins unconstrained"
    _ * Open3.capture3("gh", "api", releases_path) >> gh_ok(releases)
    _ * Open3.capture3("gh", "api", tags_path) >> gh_ok([tag_json("v2.0", "sha2"), tag_json("v1.0", "sha1"), tag_json("wip", "sha3")])
    package.versions.map(&:version) == ["wip", "v1.0", "v2.0"]
  end

  test "find skips draft releases — no tag exists until publish" do
    Given "a draft release alongside a published one"
    repo = Dev::Deps::GhRepository.new
    releases = [
      { "tag_name" => "v2.0-draft", "draft" => true, "assets" => [] },
      { "tag_name" => "v1.0", "draft" => false, "assets" => [] },
    ]

    When "finding"
    package = repo.find(prebuilt_id)

    Then
    _ * Open3.capture3("gh", "api", releases_path) >> gh_ok(releases)
    _ * Open3.capture3("gh", "api", tags_path) >> gh_ok([tag_json("v1.0", "sha1")])
    package.versions.map(&:version) == ["v1.0"]
  end

  test "find paginates list endpoints to exhaustion" do
    Given "a repo with 100 tags on page one and 1 on page two"
    repo = Dev::Deps::GhRepository.new
    page_one = (1..100).map { |i| tag_json("v#{i}", "sha#{i}") }
    page_two = [tag_json("v101", "sha101")]

    When "finding"
    package = repo.find(prebuilt_id)

    Then
    _ * Open3.capture3("gh", "api", releases_path) >> gh_ok([])
    _ * Open3.capture3("gh", "api", tags_path(page: 1)) >> gh_ok(page_one)
    _ * Open3.capture3("gh", "api", tags_path(page: 2)) >> gh_ok(page_two)
    _ * Open3.capture3("gh", "api", latest_release_path) >> gh_not_found
    package.versions.size == 101
  end

  test "find retries an empty releases list that /releases/latest contradicts" do
    Given "a releases list that answers [] once (a GitHub replica flake) while /releases/latest names a release"
    repo = Dev::Deps::GhRepository.new

    When "finding"
    package = repo.find(prebuilt_id)

    Then "the universe carries the release's facts, not the flake's tag-only view"
    _ * Kernel.sleep
    # Mocha serves the most recently declared matching expectation first, so
    # the retry's answer is declared before the first call's.
    1 * Open3.capture3("gh", "api", releases_path) >> gh_ok([RELEASE_JSON])
    1 * Open3.capture3("gh", "api", releases_path) >> gh_ok([])
    _ * Open3.capture3("gh", "api", tags_path) >> gh_ok([tag_json("5.6.1-css-83", "css83sha")])
    _ * Open3.capture3("gh", "api", latest_release_path) >> gh_ok({ "tag_name" => "5.6.1-css-83" })
    package.version("5.6.1-css-83").metadata["assets"].map { |a| a["sha256"] } == ["aaaa1111", "bbbb2222", "cccc3333"]
  end

  test "find accepts an empty releases list that /releases/latest confirms — a tag-only repo" do
    Given "no releases and /releases/latest answering 404"
    repo = Dev::Deps::GhRepository.new

    When "finding"
    package = repo.find(prebuilt_id)

    Then "one list call, no retry: the tag is the whole universe"
    0 * Kernel.sleep
    1 * Open3.capture3("gh", "api", releases_path) >> gh_ok([])
    _ * Open3.capture3("gh", "api", tags_path) >> gh_ok([tag_json("v1", "sha")])
    _ * Open3.capture3("gh", "api", latest_release_path) >> gh_not_found
    package.versions.map(&:version) == ["v1"]
    !package.version("v1").metadata.key?("assets")
  end

  test "find raises InconsistentReleasesError when the releases list stays empty against /releases/latest" do
    Given "a releases list that answers [] on every attempt while /releases/latest names a release"
    repo = Dev::Deps::GhRepository.new
    retries = Dev::Deps::GhRepository::RELEASES_RETRIES
    attempts = 1 + retries

    When "finding"
    repo.find(prebuilt_id)

    Then "it refuses rather than lock a universe missing its release facts"
    retries * Kernel.sleep
    attempts * Open3.capture3("gh", "api", releases_path) >> gh_ok([])
    _ * Open3.capture3("gh", "api", tags_path) >> gh_ok([tag_json("v1", "sha")])
    _ * Open3.capture3("gh", "api", latest_release_path) >> gh_ok({ "tag_name" => "v1" })
    raises Dev::Deps::GhRepository::InconsistentReleasesError
  end

  test "find raises ApiError when the /releases/latest cross-check itself fails" do
    Given "an empty releases list and a server error from /releases/latest"
    repo = Dev::Deps::GhRepository.new

    When "finding"
    repo.find(prebuilt_id)

    Then "an unconfirmed empty list is not believed"
    _ * Open3.capture3("gh", "api", releases_path) >> gh_ok([])
    _ * Open3.capture3("gh", "api", tags_path) >> gh_ok([tag_json("v1", "sha")])
    _ * Open3.capture3("gh", "api", latest_release_path) >> gh_failure("gh: Internal Server Error (HTTP 500)")
    raises Dev::Deps::GhRepository::ApiError
  end

  test "pause sleeps for the backoff — the clock seam the retry tests stub" do
    Given "a repository"
    repo = Dev::Deps::GhRepository.new

    When "pausing"
    repo.send(:pause, 2)

    Then
    1 * Kernel.sleep(2)
  end

  test "find claims an empty Resolved declaration set — self-contained by contract" do
    Given "a repo with one tag"
    repo = Dev::Deps::GhRepository.new

    When "finding"
    package = repo.find(prebuilt_id)

    Then
    _ * Open3.capture3("gh", "api", releases_path) >> gh_ok([])
    _ * Open3.capture3("gh", "api", tags_path) >> gh_ok([tag_json("v1", "sha")])
    _ * Open3.capture3("gh", "api", latest_release_path) >> gh_not_found
    package.version("v1").declarations == Dev::Deps::Declarations::Resolved.new([])
  end

  test "find raises PackageNotFoundError for a repo with no tags or releases" do
    Given "an empty universe"
    repo = Dev::Deps::GhRepository.new

    When "finding"
    repo.find(prebuilt_id)

    Then
    _ * Open3.capture3("gh", "api", releases_path) >> gh_ok([])
    _ * Open3.capture3("gh", "api", tags_path) >> gh_ok([])
    _ * Open3.capture3("gh", "api", latest_release_path) >> gh_not_found
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

    When "finding"
    package = repo.find(prebuilt_id)

    Then
    _ * Open3.capture3("gh", "api", releases_path) >> gh_ok([release])
    _ * Open3.capture3("gh", "api", tags_path) >> gh_ok([tag_json("v1.0", "sha")])
    assets = package.version("v1.0").metadata["assets"]
    assets.size == 1
    !assets[0].key?("sha256")
  end

  test "find raises RepoAccessError when the repo is invisible — list endpoints 404 only then" do
    Given "a 404 on the releases list"
    repo = Dev::Deps::GhRepository.new

    When "finding in an inaccessible repo"
    repo.find(prebuilt_id)

    Then
    _ * Open3.capture3("gh", "api", anything) >> gh_not_found
    raises Dev::Deps::GhRepository::RepoAccessError
  end

  test "find raises AuthenticationError when gh is not logged in" do
    Given "gh demanding authentication"
    repo = Dev::Deps::GhRepository.new
    err = "To get started with GitHub CLI, please run: gh auth login"

    When "finding without authentication"
    repo.find(prebuilt_id)

    Then
    _ * Open3.capture3("gh", "api", anything) >> gh_failure(err)
    raises Dev::Deps::GhRepository::AuthenticationError
  end

  test "find raises ApiError for other gh failures" do
    Given "a server error from gh"
    repo = Dev::Deps::GhRepository.new

    When "finding during an API outage"
    repo.find(prebuilt_id)

    Then
    _ * Open3.capture3("gh", "api", anything) >> gh_failure("gh: Internal Server Error (HTTP 500)")
    raises Dev::Deps::GhRepository::ApiError
  end

  test "find reports a series tag as its series' head — the version tag cut at the commit it points at — and as a version" do
    Given "a repo deploying heads: v1 at 1.3.0's commit while 1.4.0 is the greatest tag; no v2 yet for the 2.0.0 release"
    repo = Dev::Deps::GhRepository.new
    releases = [
      { "tag_name" => "2.0.0", "draft" => false, "assets" => [] },
      { "tag_name" => "1.4.0", "draft" => false, "assets" => [] },
      { "tag_name" => "1.3.0", "draft" => false, "assets" => [] },
    ]
    tags = [tag_json("v1", "sha13"), tag_json("2.0.0", "sha20"), tag_json("1.4.0", "sha14"), tag_json("1.3.0", "sha13")]

    When "finding"
    package = repo.find(prebuilt_id)

    Then "one head, v1 → 1.3.0; every tag is a version, the series tag included, so `tag: \"v1\"` still names it"
    _ * Open3.capture3("gh", "api", releases_path) >> gh_ok(releases)
    _ * Open3.capture3("gh", "api", tags_path) >> gh_ok(tags)
    package.heads == [Dev::Deps::SeriesHead.new(series: Dev::Lifecycle::Series.new(1), version: "1.3.0")]
    package.versions.map(&:version).sort == ["1.3.0", "1.4.0", "2.0.0", "v1"]
    package.version("v1").source == "sha13"
  end

  test "find reads a head's version through the release-tag prefix, and the greatest when several of the series sit at the commit" do
    Given "v1 at a commit carrying v1.3.0 and a re-tag v1.3.1 of the same tree, beside a tag of another series and a word"
    repo = Dev::Deps::GhRepository.new
    tags = [tag_json("v1", "sha13"), tag_json("v1.3.0", "sha13"), tag_json("v1.3.1", "sha13"), tag_json("v2.0.0", "sha13"), tag_json("stable", "sha13")]

    When "finding"
    package = repo.find(prebuilt_id)

    Then
    _ * Open3.capture3("gh", "api", releases_path) >> gh_ok([])
    _ * Open3.capture3("gh", "api", tags_path) >> gh_ok(tags)
    _ * Open3.capture3("gh", "api", latest_release_path) >> gh_not_found
    package.heads.map(&:to_s) == ["v1 → v1.3.1"]
  end

  test "find reports no head for a series tag at a commit no release of its series was cut at" do
    Given "v1 pointing at a commit with no version tag and v2 pointing at a commit of series 1"
    repo = Dev::Deps::GhRepository.new
    tags = [tag_json("v1", "shaX"), tag_json("v2", "sha13"), tag_json("v1.3.0", "sha13"), tag_json("v1.4.0", "sha14")]

    When "finding"
    pointed = repo.find(prebuilt_id)

    Then "neither pointer names a version of the universe"
    _ * Open3.capture3("gh", "api", releases_path) >> gh_ok([])
    _ * Open3.capture3("gh", "api", tags_path) >> gh_ok(tags)
    _ * Open3.capture3("gh", "api", latest_release_path) >> gh_not_found
    pointed.heads.empty?
    pointed.versions.map(&:version).sort == ["v1", "v1.3.0", "v1.4.0", "v2"]
  end

  test "find keeps no heads for a repo with no series tags at all — its channel is derived" do
    Given "a repo with version tags only"
    bare = Dev::Deps::GhRepository.new
    tags = [tag_json("v1.3.0", "sha13"), tag_json("v1.4.0", "sha14")]

    When "finding"
    derived = bare.find(prebuilt_id)

    Then
    _ * Open3.capture3("gh", "api", releases_path) >> gh_ok([])
    _ * Open3.capture3("gh", "api", tags_path) >> gh_ok(tags)
    _ * Open3.capture3("gh", "api", latest_release_path) >> gh_not_found
    derived.heads.empty?
  end

  test "at lifts a commit SHA purely — no gh call, the SHA is the version" do
    Given "a commit address"
    repo = Dev::Deps::GhRepository.new
    sha = "9cca280a4d0ccf0c08f47a99aa71d1b0e52f8d03"

    When "lifting"
    version = repo.at(Dev::Deps::PackageId.new(integration: :gh, name: "json", source: "nlohmann/json"), sha)

    Then "the address is trusted at resolve; no release facts, existence surfaces at fetch"
    0 * Open3.capture3
    version.version == sha
    version.digest.nil?
    version.metadata == { "repo" => "nlohmann/json" }
    version.declarations == Dev::Deps::Declarations::Resolved.new([])
  end

  test "find raises GhMissingError when the gh CLI is not installed" do
    Given "no gh binary on PATH"
    repo = Dev::Deps::GhRepository.new

    When "finding without gh installed"
    repo.find(prebuilt_id)

    Then
    _ * Open3.capture3 >> raises(Errno::ENOENT, "gh")
    raises Dev::Deps::GhRepository::GhMissingError
  end
end
