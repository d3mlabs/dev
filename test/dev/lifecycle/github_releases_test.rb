# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "fileutils"
require "pathname"
require "support/fake_gh"
require "tmpdir"
require "uri"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::GithubReleasesTest < Minitest::Test
  TAG = Dev::Lifecycle::ReleaseTag.new("1.2.0")
  URL = "https://github.com/d3mlabs/rspock/releases/tag/v1.2.0"

  def releases(gh)
    Dev::Lifecycle::GithubReleases.new(gh:)
  end

  test "find asks gh for the tag's release page and answers it as a URI" do
    Given
    gh = FakeGh.new.answers(["release", "view"], with: "#{URL}\n")

    When
    found = releases(gh).find(TAG)

    Then
    found == URI.parse(URL)
    gh.calls.map(&:argv) == [["release", "view", "v1.2.0", "--json", "url", "--jq", ".url"]]
  end

  test "find is nil when the forge has no release for the tag — the one refusal that is an answer" do
    Given
    gh = FakeGh.new.refuses(["release", "view"], with: "release not found")

    Expect
    releases(gh).find(TAG).nil?
  end

  test "any other refusal of a read is the archive's own error, carrying gh's words" do
    Given
    gh = FakeGh.new.refuses(["release", "view"], with: "HTTP 401: Bad credentials")

    When
    releases(gh).find(TAG)

    Then
    error = raises(Dev::Lifecycle::GithubReleases::ApiError)
    error.message.include?("Bad credentials")
  end

  test "create mints the release for a tag the forge already has, the notes on stdin, and answers its page" do
    Given
    gh = FakeGh.new.answers(["release", "create"], with: "#{URL}\n")

    When
    created = releases(gh).create(TAG, title: "v1.2.0", notes: "abc1234 add b\n")

    Then
    created == URI.parse(URL)
    gh.calls.map(&:argv) == [["release", "create", "v1.2.0", "--title", "v1.2.0", "--notes-file", "-", "--verify-tag"]]
    gh.calls.first.stdin == "abc1234 add b\n"
  end

  test "a refused create is the archive's error" do
    Given
    gh = FakeGh.new.refuses(["release", "create"], with: "tag v1.2.0 doesn't exist")

    When
    releases(gh).create(TAG, title: "v1.2.0", notes: "")

    Then
    raises(Dev::Lifecycle::GithubReleases::ApiError)
  end

  test "upload attaches every file, replacing an asset of the same name so a resumed run heals a half-attached one" do
    Given
    gh = FakeGh.new.answers(["release", "upload"], with: "")
    files = [Pathname("/tmp/x/rspock-1.2.0.zip"), Pathname("/tmp/x/release.json")]

    When
    releases(gh).upload(TAG, files)

    Then
    gh.calls.map(&:argv) == [["release", "upload", "v1.2.0", "/tmp/x/rspock-1.2.0.zip", "/tmp/x/release.json", "--clobber"]]
  end

  test "a refused upload is the archive's error, carrying gh's words" do
    Given
    gh = FakeGh.new.refuses(["release", "upload"], with: "HTTP 403: Resource not accessible by integration")

    When
    releases(gh).upload(TAG, [Pathname("/tmp/x/rspock-1.2.0.zip")])

    Then
    error = raises(Dev::Lifecycle::GithubReleases::ApiError)
    error.message.include?("Resource not accessible")
  end

  test "upload with nothing to attach does not go to the forge" do
    Given
    gh = FakeGh.new

    When
    releases(gh).upload(TAG, [])

    Then
    gh.calls.empty?
  end

  test "download fetches the named assets into the directory, creating it, each name escaped to match only itself" do
    Given
    dir = Pathname(Dir.mktmpdir("github-releases-")) / "v1.2.0"
    gh = FakeGh.new.serves("v1.2.0", "rspock-1.2.0.gem" => "gem bytes", "release.json" => "{}", "odd[1].zip" => "zip")

    When
    releases(gh).download(TAG, ["rspock-1.2.0.gem", "odd[1].zip"], into: dir)

    Then
    (dir / "rspock-1.2.0.gem").read == "gem bytes"
    (dir / "odd[1].zip").read == "zip"
    !(dir / "release.json").exist?
    gh.calls.map(&:argv) == [["release", "download", "v1.2.0", "--dir", dir.to_s, "--clobber", "--pattern", "rspock-1.2.0.gem", "--pattern", "odd\\[1].zip"]]

    Cleanup
    FileUtils.rm_rf(dir.dirname)
  end

  test "download with nothing to fetch does not go to the forge" do
    Given
    gh = FakeGh.new

    When
    releases(gh).download(TAG, [], into: Pathname("/nonexistent/releases/v1.2.0"))

    Then
    gh.calls.empty?
  end

  test "a refused download is the archive's error, carrying gh's words" do
    Given
    dir = Pathname(Dir.mktmpdir("github-releases-"))
    gh = FakeGh.new.serves("v1.2.0", "rspock-1.2.0.gem" => "gem bytes")

    When
    releases(gh).download(TAG, ["rspock-9.9.9.gem"], into: dir)

    Then
    error = raises(Dev::Lifecycle::GithubReleases::ApiError)
    error.message.include?("no assets match the file pattern")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "asset_url asks gh for the tag's assets and answers the named one's download url — the forge's statement, not a spelled layout" do
    Given
    assets = [
      { "name" => "rspock-1.2.0.gem", "url" => "https://github.com/d3mlabs/rspock/releases/download/v1.2.0/rspock-1.2.0.gem" },
      { "name" => "release.json", "url" => "https://github.com/d3mlabs/rspock/releases/download/v1.2.0/release.json" },
    ]
    gh = FakeGh.new.answers(["release", "view"], with: assets)

    When
    url = releases(gh).asset_url(TAG, "rspock-1.2.0.gem")

    Then
    url == URI.parse("https://github.com/d3mlabs/rspock/releases/download/v1.2.0/rspock-1.2.0.gem")
    gh.calls.map(&:argv) == [["release", "view", "v1.2.0", "--json", "assets", "--jq", ".assets"]]
  end

  test "asset_url refuses when the release carries no asset of that name, listing what it carries" do
    Given
    gh = FakeGh.new.answers(["release", "view"], with: [{ "name" => "release.json", "url" => "https://x/release.json" }])

    When
    releases(gh).asset_url(TAG, "rspock-1.2.0.gem")

    Then
    error = raises(Dev::Lifecycle::GithubReleases::AssetMissingError)
    error.message.include?("no asset rspock-1.2.0.gem")
    error.message.include?("release.json")
  end

  test "asset_url for a tag with no release is the same refusal: nothing is served" do
    Given
    gh = FakeGh.new.refuses(["release", "view"], with: "release not found")

    When
    releases(gh).asset_url(TAG, "rspock-1.2.0.gem")

    Then
    error = raises(Dev::Lifecycle::GithubReleases::AssetMissingError)
    error.message.include?("v1.2.0 has no release")
  end

  test "asset_url maps #{what} to the archive's own error" do
    Given
    gh = refusal ? FakeGh.new.refuses(["release", "view"], with: refusal) : FakeGh.new.answers(["release", "view"], with: printed)

    When
    releases(gh).asset_url(TAG, "rspock-1.2.0.gem")

    Then
    raises(error)

    Where
    what                   | refusal                       | printed      | error
    "a refused read"       | "HTTP 401: Bad credentials"   | nil          | Dev::Lifecycle::GithubReleases::ApiError
    "an answer not JSON"   | nil                           | "not json\n" | Dev::Lifecycle::GithubReleases::MalformedReleaseError
  end

  test "a page that is #{what} is refused: the forge did not answer a release" do
    Given
    gh = FakeGh.new.answers(["release", "view"], with: printed)

    When
    releases(gh).find(TAG)

    Then
    raises(Dev::Lifecycle::GithubReleases::MalformedReleaseError)

    Where
    what            | printed
    "empty"         | "\n"
    "not a url"     | "http://exa mple\n"
  end
end
