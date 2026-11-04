# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "support/lifecycle_fixtures"
require "fileutils"
require "json"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ManifestTest < Minitest::Test
  include LifecycleFixtures

  NOON = Time.utc(2026, 11, 4, 12, 0, 0)
  CLEAN = Dev::Lifecycle::GitState.new(sha: "3f2a1c9d8e7b", dirty: false)
  # The on-disk shape of a well-formed artifact manifest; the malformed
  # table perturbs one key at a time (Where rows evaluate in class scope,
  # so this is a constant, duplicated per row).
  DOCUMENT = {
    "stamp" => { "schema" => 1, "dev_version" => "0.7.2", "written_at" => "2026-11-04T12:00:00Z" },
    "build" => "cellbound-3d-win64-dev",
    "sha" => "3f2a1c9d8e7b",
    "dirty" => false,
    "packaged_at" => "2026-11-04T12:00:00Z",
    "builder" => "script",
    "builder_version" => nil,
    "build_id" => "1.2.0+3f2a1c9d8e7b",
    "archive" => "cellbound-3d-win64-dev.zip",
    "archive_sha256" => "ab" * 32,
  }.freeze

  test "Stamp.now records the schema, this dev's version and the instant in UTC" do
    When
    stamp = Dev::Lifecycle::Manifest::Stamp.now(dev_version: "0.7.2", now: Time.new(2026, 11, 4, 7, 0, 0, "-05:00"))

    Then
    stamp.schema == Dev::Lifecycle::Manifest::SCHEMA
    stamp.to_json_hash == { "schema" => 1, "dev_version" => "0.7.2", "written_at" => "2026-11-04T12:00:00Z" }
    Dev::Lifecycle::Manifest::Stamp.from_json_hash(stamp.to_json_hash).to_json_hash == stamp.to_json_hash
  end

  test "Stamp.now defaults to the running dev's version" do
    Expect
    Dev::Lifecycle::Manifest::Stamp.now.dev_version == Dev::Version.current
  end

  test "an artifact manifest round-trips through build-id.json in its directory" do
    Given "a manifest and an empty artifact directory"
    dir = Pathname(Dir.mktmpdir("manifest-"))
    manifest = artifact_manifest

    When "written, then read back against the same targets"
    manifest.write(dir)
    read = Dev::Lifecycle::Manifest::Artifact.read(dir, targets: all_targets)
    document = JSON.parse((dir / "build-id.json").read)

    Then "the file is the flat, string-keyed shape, and the value is equal"
    read == manifest
    read.build == build("cellbound-3d-win64-dev")
    read.state == CLEAN
    read.packaged_at == NOON
    read.builder == "script"
    read.builder_version.nil?
    read.build_id == Dev::Lifecycle::BuildId.new("1.2.0+3f2a1c9d8e7b")
    read.archive == "cellbound-3d-win64-dev.zip"
    read.archive_sha256 == "ab" * 32
    read.file_name == "build-id.json"
    document.keys == [
      "stamp", "build", "sha", "dirty", "packaged_at", "builder", "builder_version", "build_id", "archive", "archive_sha256",
    ]
    document["build"] == "cellbound-3d-win64-dev"
    document["dirty"] == false
    document["stamp"]["schema"] == 1

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an artifact is current only when packaged from a clean tree that is the tree now: packaged #{packaged.inspect}, now #{now.inspect}" do
    Given
    manifest = artifact_manifest(state: Dev::Lifecycle::GitState.new(sha: packaged[0], dirty: packaged[1]))

    Expect
    manifest.current?(Dev::Lifecycle::GitState.new(sha: now[0], dirty: now[1])) == current

    Where
    packaged                  | now                       | current
    ["3f2a1c9d8e7b", false]   | ["3f2a1c9d8e7b", false]   | true
    ["3f2a1c9d8e7b", false]   | ["3f2a1c9d8e7b", true]    | false
    ["3f2a1c9d8e7b", true]    | ["3f2a1c9d8e7b", true]    | false
    ["3f2a1c9d8e7b", false]   | ["aaaaaaaaaaaa", false]   | false
    [nil, true]               | [nil, true]               | false
  end

  test "a release manifest round-trips through release.json and is always current" do
    Given
    dir = Pathname(Dir.mktmpdir("manifest-"))
    manifest = Dev::Lifecycle::Manifest::Release.new(
      stamp: Dev::Lifecycle::Manifest::Stamp.now(dev_version: "0.7.2", now: NOON),
      tag: "v1.2.0",
      sha: "3f2a1c9d8e7b",
      archives: [
        Dev::Lifecycle::Manifest::Release::Archive.new(
          build: build("cellbound-3d-win64-release"), name: "cellbound-3d-win64-release-1.2.0.zip",
          sha256: "cd" * 32, build_id: Dev::Lifecycle::BuildId.new("1.2.0+3f2a1c9d8e7b"),
        ),
        Dev::Lifecycle::Manifest::Release::Archive.new(
          build: build("rspock"), name: "rspock-1.2.0.gem",
          sha256: "ef" * 32, build_id: Dev::Lifecycle::BuildId.new("1.2.0+3f2a1c9d8e7b"),
        ),
      ],
    )

    When
    manifest.write(dir)
    read = Dev::Lifecycle::Manifest::Release.read(dir, targets: all_targets)
    document = JSON.parse((dir / "release.json").read)

    Then
    read == manifest
    read.tag == "v1.2.0"
    read.archives.map(&:name) == ["cellbound-3d-win64-release-1.2.0.zip", "rspock-1.2.0.gem"]
    read.archives.first.build == build("cellbound-3d-win64-release")
    read.file_name == "release.json"
    read.current?(CLEAN)
    read.current?(Dev::Lifecycle::GitState.new(sha: "other", dirty: true))
    document["archives"].first == {
      "build" => "cellbound-3d-win64-release", "name" => "cellbound-3d-win64-release-1.2.0.zip",
      "sha256" => "cd" * 32, "build_id" => "1.2.0+3f2a1c9d8e7b",
    }

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "reading a directory without the file is a missing manifest" do
    Given
    dir = Pathname(Dir.mktmpdir("manifest-"))

    When
    Dev::Lifecycle::Manifest::Artifact.read(dir, targets: all_targets)

    Then
    error = raises(Dev::Lifecycle::Manifest::MissingManifestError)
    error.message.include?("no build-id.json")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a file that is not this manifest is malformed, naming the file and the fault: #{fault}" do
    Given
    dir = Pathname(Dir.mktmpdir("manifest-"))
    (dir / "build-id.json").write(content)

    When
    Dev::Lifecycle::Manifest::Artifact.read(dir, targets: all_targets)

    Then
    error = raises(Dev::Lifecycle::Manifest::MalformedManifestError)
    error.message.include?("build-id.json")
    error.message.include?(fragment)

    Cleanup
    FileUtils.rm_rf(dir)

    Where
    fault                               | content                                                            | fragment
    "bad JSON"                          | "{not json"                                                        | "expected object key"
    "not an object"                     | "[1, 2]"                                                           | "expected a JSON object"
    "a missing key"                     | JSON.generate(DOCUMENT.reject { |key, _| key == "archive" })       | "archive"
    "a build no longer declared"        | JSON.generate(DOCUMENT.merge("build" => "opencell-win64"))         | "names no declared target"
    "a build outside its target's axes" | JSON.generate(DOCUMENT.merge("build" => "cellbound-3d-macos-dev")) | "does not declare platform 'macos'"
    "an unreadable instant"             | JSON.generate(DOCUMENT.merge("packaged_at" => "noon"))             | "noon"
    "a malformed build id"    | JSON.generate(DOCUMENT.merge("build_id" => "1.2.0"))         | "not a build id"
    "a malformed stamp"       | JSON.generate(DOCUMENT.merge("stamp" => {}))                 | "schema"
  end

  test "a release manifest whose archives are not a list is malformed" do
    Given
    dir = Pathname(Dir.mktmpdir("manifest-"))
    (dir / "release.json").write(JSON.generate(
      "stamp" => { "schema" => 1, "dev_version" => "0.7.2", "written_at" => "2026-11-04T12:00:00Z" },
      "tag" => "v1.2.0", "sha" => "abc", "archives" => "none",
    ))

    When
    Dev::Lifecycle::Manifest::Release.read(dir, targets: all_targets)

    Then
    error = raises(Dev::Lifecycle::Manifest::MalformedManifestError)
    error.message.include?("archives: expected a list")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  private

  def artifact_manifest(state: CLEAN)
    Dev::Lifecycle::Manifest::Artifact.new(
      stamp: Dev::Lifecycle::Manifest::Stamp.now(dev_version: "0.7.2", now: NOON),
      build: build("cellbound-3d-win64-dev"),
      state: state,
      packaged_at: NOON,
      builder: "script",
      builder_version: nil,
      build_id: Dev::Lifecycle::BuildId.new("1.2.0+3f2a1c9d8e7b"),
      archive: "cellbound-3d-win64-dev.zip",
      archive_sha256: "ab" * 32,
    )
  end
end
