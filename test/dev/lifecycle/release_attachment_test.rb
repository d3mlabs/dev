# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "digest"
require "fileutils"
require "json"
require "pathname"
require "support/lifecycle_fixtures"
require "support/release_forge_gh"
require "time"
require "tmpdir"

# The attach over a forge that keeps what is uploaded (ReleaseForgeGh):
# the assets land under their release names and the ledger reads back
# with the entry; the real ReleaseAssets and ReleaseLedger run between.
transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ReleaseAttachmentTest < Minitest::Test
  include LifecycleFixtures

  TAG = Dev::Lifecycle::ReleaseTag.new("1.2.0")
  NOON = Time.utc(2026, 11, 6, 12, 0, 0)
  SHA = "0123456789ab"
  URL = "https://github.com/d3mlabs/cellbound-3d/releases/tag/v1.2.0"

  def setup
    @root = Pathname(Dir.mktmpdir("release-attachment-"))
    @gh = ReleaseForgeGh.new(root: @root)
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def attachment
    releases = Dev::Lifecycle::GithubReleases.new(gh: @gh)
    Dev::Lifecycle::ReleaseAttachment.new(
      releases:, ledger: Dev::Lifecycle::ReleaseLedger.new(releases:, targets: all_targets, clock: -> { NOON }),
    )
  end

  def clean
    Dev::Lifecycle::GitState.new(sha: SHA, dirty: false)
  end

  # An artifact in a store directory: the archive (and parts) written, the manifest stamped from a state.
  def artifact(build_name, archive:, files:, state: clean)
    dir = @root / "store" / build_name
    dir.mkpath
    files.each { |name, content| (dir / name).write(content) }
    manifest = Dev::Lifecycle::Manifest::Artifact.new(
      stamp: Dev::Lifecycle::Manifest::Stamp.now(now: NOON), build: build(build_name), state:, packaged_at: NOON,
      builder: "script", builder_version: nil, build_id: Dev::Lifecycle::BuildId.derive(state:, semver: "1.2.0", now: NOON),
      archive:, archive_sha256: Digest::SHA256.file((dir / archive).to_s).hexdigest,
    )
    Dev::Lifecycle::Artifact.new(dir:, manifest:)
  end

  def ledger_on_forge
    Dev::Lifecycle::Manifest::Release.from_json_hash(JSON.parse(@gh.attached("v1.2.0").fetch("release.json")), targets: all_targets)
  end

  test "assert_attachable! passes a clean tree at the tag's version with a release on the forge" do
    Given
    @gh.answers(["release", "view"], with: { "url" => URL, "isDraft" => true })

    When
    attachment.assert_attachable!(TAG, state: clean, version: "1.2.0")

    Then
    @gh.calls.map(&:argv) == [["release", "view", "v1.2.0", "--json", "url,isDraft"]]
  end

  test "a project keeping no version in source is attachable by its tree alone" do
    Given
    @gh.answers(["release", "view"], with: { "url" => URL, "isDraft" => true })

    When
    attachment.assert_attachable!(TAG, state: clean, version: nil)

    Then
    @gh.calls.size == 1
  end

  test "a tree that is #{what} is refused before the forge is asked: nothing packaged from it is the release's" do
    When
    attachment.assert_attachable!(TAG, state: Dev::Lifecycle::GitState.new(sha:, dirty:), version: "1.2.0")

    Then
    error = raises(Dev::Lifecycle::ReleaseAttachment::NotAtReleaseError)
    error.message.include?(said)
    error.message.include?("a release attaches what was packaged from a clean tree at its tag")
    @gh.calls.empty?

    Where
    what             | sha            | dirty | said
    "dirty"          | "0123456789ab" | true  | "the tree is not clean"
    "not a checkout" | nil            | true  | "the tree is not a checkout"
  end

  test "a VERSION that is not the tag's is refused by both numbers: the tree is not at the tag" do
    When
    attachment.assert_attachable!(TAG, state: clean, version: "1.1.0")

    Then
    error = raises(Dev::Lifecycle::ReleaseAttachment::NotAtReleaseError)
    error.message == "VERSION reads 1.1.0, not 1.2.0: the tree is not at v1.2.0 — a release attaches what was packaged at its tag"
    @gh.calls.empty?
  end

  test "a tag with no release on the forge is refused naming the `dev release` that creates it" do
    Given
    @gh.refuses(["release", "view"], with: "release not found")

    When
    attachment.assert_attachable!(TAG, state: clean, version: "1.2.0")

    Then
    error = raises(Dev::Lifecycle::ReleaseAttachment::NoReleaseError)
    error.message == "v1.2.0 has no release on the forge to attach to — `dev release 1.2.0` creates it, then attaches"
  end

  test "attach uploads the archive under its release name, then records the build's entry on the ledger at the artifact's commit (dev#744)" do
    Given
    zipped = artifact("cellbound-3d-win64-release", archive: "cellbound-3d-win64-release.zip", files: { "cellbound-3d-win64-release.zip" => "zip bytes" })

    When
    entry = attachment.attach(zipped, tag: TAG)

    Then "the forge holds the asset and release.json with the one entry; the assets went up before the ledger"
    @gh.attached("v1.2.0").keys == ["cellbound-3d-win64-release-1.2.0.zip", "release.json"]
    @gh.attached("v1.2.0").fetch("cellbound-3d-win64-release-1.2.0.zip") == "zip bytes"
    entry.to_json_hash == {
      "build" => "cellbound-3d-win64-release", "name" => "cellbound-3d-win64-release-1.2.0.zip",
      "sha256" => Digest::SHA256.hexdigest("zip bytes"), "build_id" => "1.2.0+#{SHA}",
    }
    ledger_on_forge.sha == SHA
    ledger_on_forge.archives.map(&:to_json_hash) == [entry.to_json_hash]
    @gh.calls.map { |call| call.argv.first(2) } == [["release", "upload"], ["release", "view"], ["release", "upload"]]
    @gh.calls[0].argv.map { |word| File.basename(word) } == ["release", "upload", "v1.2.0", "cellbound-3d-win64-release-1.2.0.zip", "--clobber"]
  end

  test "a split archive attaches its parts and rewritten MANIFEST, the entry digesting the MANIFEST" do
    Given
    parts = { "rspock.tar.zst.00" => "part zero", "rspock.tar.zst.01" => "part one" }
    manifest_lines = parts.map { |name, content| "#{Digest::SHA256.hexdigest(content)}  #{name}\n" }.join
    split = artifact("rspock", archive: "rspock.MANIFEST", files: parts.merge("rspock.MANIFEST" => manifest_lines))

    When
    entry = attachment.attach(split, tag: TAG)

    Then
    @gh.attached("v1.2.0").keys == ["rspock-1.2.0.MANIFEST", "rspock-1.2.0.tar.zst.00", "rspock-1.2.0.tar.zst.01", "release.json"]
    entry.name == "rspock-1.2.0.MANIFEST"
    entry.sha256 == Digest::SHA256.hexdigest(@gh.attached("v1.2.0").fetch("rspock-1.2.0.MANIFEST"))
  end

  test "a second build's attach keeps the first's entry beside its own" do
    Given
    client = artifact("cellbound-3d-win64-release", archive: "cellbound-3d-win64-release.zip", files: { "cellbound-3d-win64-release.zip" => "client" })
    server = artifact("cellbound-3d-server-linux64-release", archive: "cellbound-3d-server-linux64-release.zip",
      files: { "cellbound-3d-server-linux64-release.zip" => "server" })
    attachment.attach(client, tag: TAG)

    When
    attachment.attach(server, tag: TAG)

    Then
    ledger_on_forge.archives.map(&:build).map(&:name) == ["cellbound-3d-win64-release", "cellbound-3d-server-linux64-release"]
  end

  test "an artifact stamped from a dirty tree is refused at the attach too, before anything is uploaded" do
    Given
    dirty = Dev::Lifecycle::GitState.new(sha: SHA, dirty: true)
    stamped = artifact("rspock", archive: "rspock.zip", files: { "rspock.zip" => "x" }, state: dirty)

    When
    attachment.attach(stamped, tag: TAG)

    Then
    raises(Dev::Lifecycle::ReleaseAttachment::NotAtReleaseError)
    @gh.calls.empty?
  end

  test "an upload the forge refuses because the release is frozen is the archive's own error" do
    Given
    gh = FakeGh.new.refuses(["release", "upload"], with: "HTTP 422: Cannot upload assets to an immutable release.")
    @gh = gh
    zipped = artifact("rspock", archive: "rspock.zip", files: { "rspock.zip" => "x" })

    When
    attachment.attach(zipped, tag: TAG)

    Then
    raises(Dev::Lifecycle::GithubReleases::FrozenError)
  end
end
