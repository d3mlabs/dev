# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "json"
require "support/release_fixtures"
require "support/release_forge_gh"
require "time"

# The ledger over a forge that keeps what is uploaded (ReleaseForgeGh), so
# a record is read back by the next one as the real forge would serve it.
transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ReleaseLedgerTest < Minitest::Test
  include ReleaseFixtures

  TAG = Dev::Lifecycle::ReleaseTag.new("1.2.0")
  NOON = Time.utc(2026, 11, 6, 12, 0, 0)
  LATER = Time.utc(2026, 11, 6, 12, 5, 0)
  SHA = "3f2a1c9d8e7b"

  def setup
    @gh = ReleaseForgeGh.new
  end

  def ledger(now: NOON)
    Dev::Lifecycle::ReleaseLedger.new(releases: Dev::Lifecycle::GithubReleases.new(gh: @gh), targets: all_targets, clock: -> { now })
  end

  # What the forge holds as `release.json`, read as the manifest.
  def uploaded
    Dev::Lifecycle::Manifest::Release.from_json_hash(JSON.parse(@gh.attached("v1.2.0").fetch("release.json")), targets: all_targets)
  end

  test "read is nil before any attach recorded: the release carries no release.json yet" do
    Expect
    ledger.read(TAG).nil?
    @gh.calls.map(&:argv) == [["release", "view", "v1.2.0", "--json", "assets", "--jq", ".assets"]]
  end

  test "the first record writes a ledger of one entry at the build's commit and uploads it (dev#744)" do
    Given
    entry = release_entry("cellbound-3d-win64-release", bytes: "zip")

    When
    recorded = ledger.record(TAG, entry, sha: SHA)

    Then "the ledger names the tag, the commit and the one entry; the forge holds the same"
    recorded.tag == "v1.2.0"
    recorded.sha == SHA
    recorded.archives.map(&:to_json_hash) == [entry.to_json_hash]
    recorded.stamp.written_at == NOON
    uploaded == recorded
    @gh.calls.map { |call| call.argv.first(3) } == [
      ["release", "view", "v1.2.0"], ["release", "upload", "v1.2.0"],
    ]
    @gh.calls.last.argv.last == "--clobber"
  end

  test "a second build's record reads the ledger back and adds its entry after the first; a build recorded again replaces its own" do
    Given
    client = release_entry("cellbound-3d-win64-release", bytes: "zip")
    server = release_entry("cellbound-3d-server-linux64-release", bytes: "server")
    client_again = release_entry("cellbound-3d-win64-release", bytes: "zip again")
    ledger.record(TAG, client, sha: SHA)

    When
    ledger.record(TAG, server, sha: SHA)
    ledger.record(TAG, client_again, sha: SHA)

    Then "two entries, the replaced one last, the other kept as it was"
    uploaded.archives.map(&:to_json_hash) == [server.to_json_hash, client_again.to_json_hash]
    @gh.downloaded("v1.2.0") == [["release.json"], ["release.json"]]
  end

  test "complete writes the final ledger: the given commit and entries in the given order, stamped now, whatever was recorded" do
    Given
    client = release_entry("cellbound-3d-win64-release", bytes: "zip")
    server = release_entry("cellbound-3d-server-linux64-release", bytes: "server")
    ledger.record(TAG, server, sha: SHA)

    When
    final = ledger(now: LATER).complete(TAG, sha: "#{SHA}0123456789abcdef0123456789ab", archives: [client, server])

    Then
    final.sha == "#{SHA}0123456789abcdef0123456789ab"
    final.archives.map(&:to_json_hash) == [client.to_json_hash, server.to_json_hash]
    final.stamp.written_at == LATER
    uploaded == final
    @gh.calls.last.argv.first(3) == ["release", "upload", "v1.2.0"]
  end

  test "read of a tag with no release is the forge's refusal" do
    Given
    gh = FakeGh.new.refuses(["release", "view"], with: "release not found")

    When
    Dev::Lifecycle::ReleaseLedger.new(releases: Dev::Lifecycle::GithubReleases.new(gh:), targets: all_targets).read(TAG)

    Then
    raises(Dev::Lifecycle::GithubReleases::AssetMissingError)
  end
end
