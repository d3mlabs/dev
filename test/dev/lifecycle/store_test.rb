# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "support/lifecycle_fixtures"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::StoreTest < Minitest::Test
  include LifecycleFixtures

  NOON = Time.utc(2026, 11, 4, 12, 0, 0)
  CLEAN = Dev::Lifecycle::GitState.new(sha: "3f2a1c9d8e7b", dirty: false)

  test "the store keys by project name and build under <data root>/artifacts" do
    Given
    root = Dir.mktmpdir("store-")
    store = Dev::Lifecycle::Store.new(project_name: "cellbound-3d", targets: all_targets, data_root: root)

    Expect
    store.root == Pathname(root) / "artifacts/cellbound-3d"
    store.dir(build("cellbound-3d-win64-dev")) == Pathname(root) / "artifacts/cellbound-3d/cellbound-3d-win64-dev"
    store.dir(build("rspock")) == Pathname(root) / "artifacts/cellbound-3d/rspock"
    store.artifact(build("cellbound-3d-win64-dev")).nil?
    store.artifacts == []

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "stamp writes build-id.json into the build's directory and the artifact reads back from it" do
    Given
    root = Dir.mktmpdir("store-")
    store = Dev::Lifecycle::Store.new(project_name: "cellbound-3d", targets: all_targets, data_root: root)
    manifest = artifact_manifest("cellbound-3d-win64-dev")

    When
    stamped = store.stamp(manifest)
    stamped.dir.join(manifest.archive).write("zip bytes")

    Then
    stamped.dir == store.dir(build("cellbound-3d-win64-dev"))
    (stamped.dir / "build-id.json").file?
    stamped.manifest == manifest
    stamped.build == build("cellbound-3d-win64-dev")
    stamped.name == "cellbound-3d-win64-dev"
    stamped.archive == stamped.dir / "cellbound-3d-win64-dev.zip"
    stamped.archive.read == "zip bytes"
    stamped.current?(CLEAN)
    !stamped.current?(Dev::Lifecycle::GitState.new(sha: "3f2a1c9d8e7b", dirty: true))
    store.artifact(build("cellbound-3d-win64-dev")) == stamped
    store.artifacts == [stamped]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "artifacts lists every stamped declared build in target order, skipping unstamped and undeclared directories" do
    Given "two stamped builds, a packaging that never finished, and an orphan from a renamed target"
    root = Dir.mktmpdir("store-")
    store = Dev::Lifecycle::Store.new(project_name: "cellbound-3d", targets: all_targets, data_root: root)
    gem = store.stamp(artifact_manifest("rspock"))
    client = store.stamp(artifact_manifest("cellbound-3d-linux64-release"))
    (store.root / "cellbound-3d-win64-dev").mkpath
    (store.root / "cellbound-3d-win64-dev/partial.zip").write("")
    (store.root / "opencell-win64-dev").mkpath
    (store.root / "opencell-win64-dev/build-id.json").write("{}")

    Expect
    store.artifacts == [client, gem]
    store.artifact(build("cellbound-3d-win64-dev")).nil?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a directory whose manifest is of another build is corrupt, and an error" do
    Given "a manifest of one build written under another build's directory"
    root = Dir.mktmpdir("store-")
    store = Dev::Lifecycle::Store.new(project_name: "cellbound-3d", targets: all_targets, data_root: root)
    wrong_dir = store.dir(build("cellbound-3d-win64-release"))
    wrong_dir.mkpath
    artifact_manifest("cellbound-3d-win64-dev").write(wrong_dir)

    When
    store.artifact(build("cellbound-3d-win64-release"))

    Then
    error = raises(Dev::Lifecycle::Store::MisnamedArtifactError)
    error.message.include?("named for cellbound-3d-win64-release")
    error.message.include?("says cellbound-3d-win64-dev")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a manifest that cannot be read surfaces as the manifest's own error" do
    Given
    root = Dir.mktmpdir("store-")
    store = Dev::Lifecycle::Store.new(project_name: "cellbound-3d", targets: all_targets, data_root: root)
    dir = store.dir(build("rspock"))
    dir.mkpath
    (dir / "build-id.json").write("{not json")

    When
    store.artifacts

    Then
    raises Dev::Lifecycle::Manifest::MalformedManifestError

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "artifacts are values over their directory and manifest" do
    Given
    root = Dir.mktmpdir("store-")
    store = Dev::Lifecycle::Store.new(project_name: "cellbound-3d", targets: all_targets, data_root: root)
    manifest = artifact_manifest("rspock")

    Expect
    Dev::Lifecycle::Artifact.new(dir: store.dir(build("rspock")), manifest: manifest) ==
      Dev::Lifecycle::Artifact.new(dir: store.dir(build("rspock")), manifest: manifest)
    Dev::Lifecycle::Artifact.new(dir: store.dir(build("rspock")), manifest: manifest).hash ==
      Dev::Lifecycle::Artifact.new(dir: store.dir(build("rspock")), manifest: manifest).hash
    Dev::Lifecycle::Artifact.new(dir: store.dir(build("rspock")), manifest: manifest) !=
      Dev::Lifecycle::Artifact.new(dir: store.root / "elsewhere", manifest: manifest)

    Cleanup
    FileUtils.rm_rf(root)
  end

  private

  def artifact_manifest(build_name)
    Dev::Lifecycle::Manifest::Artifact.new(
      stamp: Dev::Lifecycle::Manifest::Stamp.now(dev_version: "0.7.2", now: NOON),
      build: build(build_name),
      state: CLEAN,
      packaged_at: NOON,
      builder: "script",
      builder_version: nil,
      build_id: Dev::Lifecycle::BuildId.new("1.2.0+3f2a1c9d8e7b"),
      archive: "#{build_name}.zip",
      archive_sha256: "ab" * 32,
    )
  end
end
