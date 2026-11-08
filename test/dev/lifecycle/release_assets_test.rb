# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "digest"
require "fileutils"
require "pathname"
require "support/lifecycle_fixtures"
require "time"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ReleaseAssetsTest < Minitest::Test
  include LifecycleFixtures

  TAG = Dev::Lifecycle::ReleaseTag.new("1.2.0")
  NOON = Time.utc(2026, 11, 6, 12, 0, 0)

  def setup
    @root = Pathname(Dir.mktmpdir("release-assets-"))
    @gather = @root / "gather"
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  # An artifact in a store directory: the archive (and parts) written, the manifest stamped.
  def artifact(build_name, archive:, files: {})
    build = build(build_name)
    dir = @root / "store" / build_name
    dir.mkpath
    files.each { |name, content| (dir / name).write(content) }
    manifest = Dev::Lifecycle::Manifest::Artifact.new(
      stamp: Dev::Lifecycle::Manifest::Stamp.now(dev_version: "0.7.6", now: NOON),
      build:, state: Dev::Lifecycle::GitState.new(sha: "0123456789ab", dirty: false), packaged_at: NOON,
      builder: "script", builder_version: nil, build_id: Dev::Lifecycle::BuildId.new("1.2.0+0123456789ab"),
      archive:, archive_sha256: Digest::SHA256.file((dir / archive).to_s).hexdigest,
    )
    Dev::Lifecycle::Artifact.new(dir:, manifest:)
  end

  test "a one-file archive is linked under <build>-<version>.<ext>, its entry carrying the store's digest and build id" do
    Given
    zipped = artifact("cellbound-3d-win64-release", archive: "cellbound-3d-win64-release.zip", files: { "cellbound-3d-win64-release.zip" => "zip bytes" })

    When
    gathered = Dev::Lifecycle::ReleaseAssets.new(dir: @gather).gather(zipped, tag: TAG)

    Then
    gathered.files == [@gather / "cellbound-3d-win64-release-1.2.0.zip"]
    (@gather / "cellbound-3d-win64-release-1.2.0.zip").symlink?
    (@gather / "cellbound-3d-win64-release-1.2.0.zip").read == "zip bytes"
    gathered.archive.to_json_hash == {
      "build" => "cellbound-3d-win64-release", "name" => "cellbound-3d-win64-release-1.2.0.zip",
      "sha256" => Digest::SHA256.hexdigest("zip bytes"), "build_id" => "1.2.0+0123456789ab",
    }
  end

  test "an extension with dots keeps them: <build>.tar.zst → <build>-<version>.tar.zst" do
    Given
    tarred = artifact("rspock", archive: "rspock.tar.zst", files: { "rspock.tar.zst" => "tar" })

    Expect
    Dev::Lifecycle::ReleaseAssets.new(dir: @gather).gather(tarred, tag: TAG).archive.name == "rspock-1.2.0.tar.zst"
  end

  test "a split archive: each part linked under its release name and a MANIFEST naming them written, its own digest recorded" do
    Given
    parts = { "rspock.tar.zst.00" => "part zero", "rspock.tar.zst.01" => "part one" }
    manifest_lines = parts.map { |name, content| "#{Digest::SHA256.hexdigest(content)}  #{name}\n" }.join
    split = artifact("rspock", archive: "rspock.MANIFEST", files: parts.merge("rspock.MANIFEST" => manifest_lines))

    When
    gathered = Dev::Lifecycle::ReleaseAssets.new(dir: @gather).gather(split, tag: TAG)

    Then
    gathered.files.map { |file| file.basename.to_s } == ["rspock-1.2.0.MANIFEST", "rspock-1.2.0.tar.zst.00", "rspock-1.2.0.tar.zst.01"]
    (@gather / "rspock-1.2.0.tar.zst.01").read == "part one"
    (@gather / "rspock-1.2.0.MANIFEST").read ==
      "#{Digest::SHA256.hexdigest("part zero")}  rspock-1.2.0.tar.zst.00\n#{Digest::SHA256.hexdigest("part one")}  rspock-1.2.0.tar.zst.01\n"
    gathered.archive.name == "rspock-1.2.0.MANIFEST"
    gathered.archive.sha256 == Digest::SHA256.file((@gather / "rspock-1.2.0.MANIFEST").to_s).hexdigest
  end

  test "a MANIFEST line that is not `<sha>  <part>` is refused by name" do
    Given
    split = artifact("rspock", archive: "rspock.MANIFEST", files: { "rspock.MANIFEST" => "garbage\n" })

    When
    Dev::Lifecycle::ReleaseAssets.new(dir: @gather).gather(split, tag: TAG)

    Then
    error = raises(Dev::Lifecycle::PartList::MalformedPartListError)
    error.message.include?("'garbage'")
  end

  test "an archive not named for its build is refused: the <build>.<ext> contract is what the release name is built on" do
    Given
    stray = artifact("rspock", archive: "gem.zip", files: { "gem.zip" => "x" })

    When
    Dev::Lifecycle::ReleaseAssets.new(dir: @gather).gather(stray, tag: TAG)

    Then
    error = raises(Dev::Lifecycle::ReleaseAssets::UnnamedArchiveError)
    error.message.include?("'gem.zip' is not named for its build")
  end

  test "gathering twice into one directory replaces the link, so a resumed run never trips on its predecessor" do
    Given
    first = artifact("rspock", archive: "rspock.zip", files: { "rspock.zip" => "old" })
    assets = Dev::Lifecycle::ReleaseAssets.new(dir: @gather)
    assets.gather(first, tag: TAG)
    (first.dir / "rspock.zip").write("new")

    When
    assets.gather(first, tag: TAG)

    Then
    (@gather / "rspock-1.2.0.zip").read == "new"
  end
end
