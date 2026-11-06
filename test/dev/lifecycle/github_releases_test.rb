# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "pathname"
require "support/fake_gh"
require "uri"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::GithubReleasesTest < Minitest::Test
  TAG = Dev::Lifecycle::ReleaseTag.new("1.2.0")
  URL = "https://github.com/d3mlabs/rspock/releases/tag/v1.2.0"

  def releases(gh) = Dev::Lifecycle::GithubReleases.new(gh:)

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

  test "upload with nothing to attach does not go to the forge" do
    Given
    gh = FakeGh.new

    When
    releases(gh).upload(TAG, [])

    Then
    gh.calls.empty?
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
