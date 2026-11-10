# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "digest"
require "fileutils"
require "pathname"
require "support/fake_gh"
require "support/release_fixtures"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ReleaseArchivesTest < Minitest::Test
  include ReleaseFixtures

  TAG = Dev::Lifecycle::ReleaseTag.new("1.2.0")

  def setup
    @root = Pathname(Dir.mktmpdir("release-archives-"))
    @gh = FakeGh.new
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def store
    Dev::Lifecycle::Store.new(project_name: "cellbound-3d", targets: all_targets, data_root: @root.to_s)
  end

  def archives
    Dev::Lifecycle::ReleaseArchives.new(releases: Dev::Lifecycle::GithubReleases.new(gh: @gh), store:, targets: all_targets)
  end

  def release_dir
    store.release_dir(TAG)
  end

  test "manifest looks the release up, downloads release.json into the store's .releases/<tag>/ and reads it" do
    Given
    served = release_on(@gh, { "rspock" => "gem bytes" })

    When
    read = archives.manifest(TAG)

    Then
    read == served
    (release_dir / "release.json").file?
    @gh.downloaded("v1.2.0") == [["release.json"]]
  end

  test "a tag with no release is refused with the release command that cuts it, before anything is downloaded" do
    Given
    @gh.refuses(["release", "view"], with: "release not found")

    When
    archives.manifest(TAG)

    Then
    error = raises(Dev::Lifecycle::ReleaseArchives::NoReleaseError)
    error.message == "v1.2.0 has no release on the forge — `dev release 1.2.0` cuts it"
    @gh.downloaded("v1.2.0") == []
  end

  test "a release.json naming another tag than the one it came from is refused: not a release dev cut" do
    Given
    release_on(@gh, { "rspock" => "gem bytes" }, manifest: release_manifest({ "rspock" => "gem bytes" }, tag: "v9.9.9"))

    When
    archives.manifest(TAG)

    Then
    error = raises(Dev::Lifecycle::ReleaseArchives::TagMismatchError)
    error.message.include?("v1.2.0's release.json says it is v9.9.9")
  end

  test "fetch downloads the selected archives, verifies each against release.json, and hands back shipments with the release as provenance" do
    Given "a release of three builds, two selected"
    served = release_on(@gh, { "cellbound-3d-win64-release" => "win bytes", "cellbound-3d-linux64-release" => "linux bytes", "rspock" => "gem bytes" })
    entries = [served.archive(build("cellbound-3d-win64-release")), served.archive(build("rspock"))]

    When
    shipments = archives.fetch(entries, release: served, tag: TAG)

    Then
    shipments.map(&:name) == ["cellbound-3d-win64-release", "rspock"]
    shipments.map(&:archive) == [release_dir / "cellbound-3d-win64-release-1.2.0.zip", release_dir / "rspock-1.2.0.zip"]
    shipments.first.archive.read == "win bytes"
    shipments.first.archive_sha256 == Digest::SHA256.hexdigest("win bytes")
    shipments.first.build_id == Dev::Lifecycle::BuildId.new("1.2.0+3f2a1c9d8e7b")
    shipments.map(&:provenance).uniq == [Dev::Lifecycle::Provenance::Release.new(tag: TAG, sha: RELEASE_SHA)]
    !(release_dir / "cellbound-3d-linux64-release-1.2.0.zip").exist?
    @gh.downloaded("v1.2.0") == [["cellbound-3d-win64-release-1.2.0.zip", "rspock-1.2.0.zip"]]
  end

  test "an archive already in .releases/<tag>/ that verifies is not downloaded again; one that does not is" do
    Given "one verified download kept, one corrupted"
    served = release_on(@gh, { "cellbound-3d-win64-release" => "win bytes", "rspock" => "gem bytes" })
    release_dir.mkpath
    (release_dir / "cellbound-3d-win64-release-1.2.0.zip").write("win bytes")
    (release_dir / "rspock-1.2.0.zip").write("stale bytes")

    When
    shipments = archives.fetch(served.archives, release: served, tag: TAG)

    Then
    @gh.downloaded("v1.2.0") == [["rspock-1.2.0.zip"]]
    shipments.last.archive.read == "gem bytes"
  end

  test "a downloaded archive whose digest is not release.json's is removed and refused" do
    Given "the forge serves other bytes than the cut digested"
    served = release_on(@gh, { "rspock" => "gem bytes" }, manifest: release_manifest({ "rspock" => "the bytes the cut digested" }))

    When
    archives.fetch(served.archives, release: served, tag: TAG)

    Then
    error = raises(Dev::Lifecycle::ReleaseArchives::ChecksumMismatchError)
    error.message.include?("rspock-1.2.0.zip hashes to #{Digest::SHA256.hexdigest("gem bytes")}, not the #{Digest::SHA256.hexdigest("the bytes the cut digested")} its release.json records")
    !(release_dir / "rspock-1.2.0.zip").exist?
  end

  test "a split set: the MANIFEST is verified against release.json, then every part it lists is downloaded and verified against it" do
    Given "a release whose linux64 archive is a MANIFEST over two parts"
    parts = { "cellbound-3d-linux64-release-1.2.0.tar.zst.aa" => "part a", "cellbound-3d-linux64-release-1.2.0.tar.zst.ab" => "part b" }
    manifest_bytes = parts.map { |name, bytes| "#{Digest::SHA256.hexdigest(bytes)}  #{name}\n" }.join
    entry = Dev::Lifecycle::Manifest::Release::Archive.new(
      build: build("cellbound-3d-linux64-release"), name: "cellbound-3d-linux64-release-1.2.0.MANIFEST",
      sha256: Digest::SHA256.hexdigest(manifest_bytes), build_id: Dev::Lifecycle::BuildId.new("1.2.0+3f2a1c9d8e7b"),
    )
    served = Dev::Lifecycle::Manifest::Release.new(stamp: Dev::Lifecycle::Manifest::Stamp.now(dev_version: "0.7.2", now: RELEASE_NOON), tag: "v1.2.0", sha: RELEASE_SHA, archives: [entry])
    @gh.serves("v1.2.0", parts.merge("cellbound-3d-linux64-release-1.2.0.MANIFEST" => manifest_bytes))

    When
    shipments = archives.fetch([entry], release: served, tag: TAG)

    Then
    shipments.map(&:archive) == [release_dir / "cellbound-3d-linux64-release-1.2.0.MANIFEST"]
    (release_dir / "cellbound-3d-linux64-release-1.2.0.tar.zst.aa").read == "part a"
    (release_dir / "cellbound-3d-linux64-release-1.2.0.tar.zst.ab").read == "part b"
    @gh.downloaded("v1.2.0") == [["cellbound-3d-linux64-release-1.2.0.MANIFEST"], parts.keys]
  end

  test "a part whose digest is not the MANIFEST's is removed and refused, naming the MANIFEST" do
    Given
    manifest_bytes = "#{Digest::SHA256.hexdigest("the part the cut digested")}  cellbound-3d-linux64-release-1.2.0.tar.zst.aa\n"
    entry = Dev::Lifecycle::Manifest::Release::Archive.new(
      build: build("cellbound-3d-linux64-release"), name: "cellbound-3d-linux64-release-1.2.0.MANIFEST",
      sha256: Digest::SHA256.hexdigest(manifest_bytes), build_id: Dev::Lifecycle::BuildId.new("1.2.0+3f2a1c9d8e7b"),
    )
    served = Dev::Lifecycle::Manifest::Release.new(stamp: Dev::Lifecycle::Manifest::Stamp.now(dev_version: "0.7.2", now: RELEASE_NOON), tag: "v1.2.0", sha: RELEASE_SHA, archives: [entry])
    @gh.serves("v1.2.0", "cellbound-3d-linux64-release-1.2.0.MANIFEST" => manifest_bytes, "cellbound-3d-linux64-release-1.2.0.tar.zst.aa" => "other part")

    When
    archives.fetch([entry], release: served, tag: TAG)

    Then
    error = raises(Dev::Lifecycle::ReleaseArchives::ChecksumMismatchError)
    error.message.include?("its cellbound-3d-linux64-release-1.2.0.MANIFEST records")
    !(release_dir / "cellbound-3d-linux64-release-1.2.0.tar.zst.aa").exist?
  end

  test "an asset the release no longer has is the forge's refusal" do
    Given
    served = release_on(@gh, { "rspock" => "gem bytes" })
    entry = served.archives.first
    missing = Dev::Lifecycle::Manifest::Release::Archive.new(build: entry.build, name: "rspock-1.2.0.gem", sha256: entry.sha256, build_id: entry.build_id)

    When
    archives.fetch([missing], release: served, tag: TAG)

    Then
    raises(Dev::Lifecycle::GithubReleases::ApiError)
  end
end
