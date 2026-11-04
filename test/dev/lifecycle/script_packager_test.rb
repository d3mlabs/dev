# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "support/lifecycle_fixtures"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ScriptPackagerTest < Minitest::Test
  include LifecycleFixtures

  test "the package: line sees the build, the install and DEV_ARTIFACT, and what it writes at <archive>.* is read back" do
    Given "a script that writes its own extension onto DEV_ARTIFACT"
    root = Pathname(Dir.mktmpdir("script-packager-"))
    project = root / "project"
    project.mkpath
    (project / "package.sh").write(<<~SH)
      #!/bin/sh
      set -eu
      echo "$DEV_TARGET $DEV_PLATFORM $DEV_CONFIG $DEV_INSTALL" > env.txt
      cp "$DEV_INSTALL/mod.zip" "$DEV_ARTIFACT.zip"
    SH
    install = root / "install"
    install.mkpath
    (install / "mod.zip").write("zip bytes")
    packager = Dev::Lifecycle::ScriptPackager.new(command: "sh ./package.sh", project_root: project)
    archive = root / "store/cellbound-3d-win64-release/cellbound-3d-win64-release"

    When
    packed = packager.package(build("cellbound-3d-win64-release"), install, archive)

    Then
    packed == Dev::Lifecycle::PackedArchive.new(archive: root / "store/cellbound-3d-win64-release/cellbound-3d-win64-release.zip")
    packed.archive.read == "zip bytes"
    (project / "env.txt").read == "cellbound-3d win64 release #{install}\n"
    packager.command == "sh ./package.sh"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "several files written are the archive (lexically first) and its parts — dev's own split naming reads back as such" do
    Given
    root = Pathname(Dir.mktmpdir("script-packager-"))
    script = 'printf a > "$DEV_ARTIFACT.tar.zst.00"; printf b > "$DEV_ARTIFACT.tar.zst.01"; printf m > "$DEV_ARTIFACT.MANIFEST"'
    packager = Dev::Lifecycle::ScriptPackager.new(command: script, project_root: root)
    archive = root / "store/rspock"

    When
    packed = packager.package(build("rspock"), root / "install", archive)

    Then
    packed.archive == root / "store/rspock.MANIFEST"
    packed.parts == [root / "store/rspock.tar.zst.00", root / "store/rspock.tar.zst.01"]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "files already there before the script ran are not what it wrote" do
    Given "a previous packaging's zip beside the new one"
    root = Pathname(Dir.mktmpdir("script-packager-"))
    (root / "store").mkpath
    (root / "store/rspock.old").write("stale")
    packager = Dev::Lifecycle::ScriptPackager.new(command: 'printf g > "$DEV_ARTIFACT.gem"', project_root: root)

    When
    packed = packager.package(build("rspock"), root / "install", root / "store/rspock")

    Then
    packed == Dev::Lifecycle::PackedArchive.new(archive: root / "store/rspock.gem")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a script that exits nonzero is reported with the exit code" do
    Given
    root = Pathname(Dir.mktmpdir("script-packager-"))
    packager = Dev::Lifecycle::ScriptPackager.new(command: "exit 3", project_root: root)

    When
    packager.package(build("rspock"), root / "install", root / "store/rspock")

    Then
    error = raises(Dev::Lifecycle::ScriptPackager::PackageScriptFailedError)
    error.message == "package script `exit 3` for rspock exited 3"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a script that exits 0 without writing <archive>.* is an error naming the contract" do
    Given
    root = Pathname(Dir.mktmpdir("script-packager-"))
    packager = Dev::Lifecycle::ScriptPackager.new(command: "true", project_root: root)

    When
    packager.package(build("rspock"), root / "install", root / "store/rspock")

    Then
    error = raises(Dev::Lifecycle::ScriptPackager::NothingPackagedError)
    error.message.include?("DEV_ARTIFACT=#{root / "store/rspock"}.<ext>")

    Cleanup
    FileUtils.rm_rf(root)
  end
end
