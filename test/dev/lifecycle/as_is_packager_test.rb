# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "support/lifecycle_fixtures"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::AsIsPackagerTest < Minitest::Test
  include LifecycleFixtures

  test "the one file in the stage is adopted under the build's name with its own extension: #{file}" do
    Given
    root = Pathname(Dir.mktmpdir("as-is-"))
    stage = root / "stage"
    stage.mkpath
    (stage / file).write("bytes")

    When
    packed = Dev::Lifecycle::AsIsPackager.new.package(build("rspock"), stage, root / "store/rspock")

    Then
    packed == Dev::Lifecycle::PackedArchive.new(archive: root / "store/#{adopted}")
    packed.archive.read == "bytes"
    (stage / file).file?

    Cleanup
    FileUtils.rm_rf(root)

    Where
    file                   | adopted
    "rspock-1.0.0.gem"     | "rspock.gem"
    "SnappyMod-Win64.zip"  | "rspock.zip"
    "toolchain.tar.zst"    | "rspock.tar.zst"
    "image.tar"            | "rspock.tar"
    "payload"              | "rspock"
  end

  test "a stage with no file has nothing to adopt: #{description}" do
    Given
    root = Pathname(Dir.mktmpdir("as-is-"))
    stage = root / "stage"
    (stage / "sub").mkpath if present

    When
    Dev::Lifecycle::AsIsPackager.new.package(build("rspock"), stage, root / "store/rspock")

    Then
    error = raises(Dev::Lifecycle::AsIsPackager::NoStageFileError)
    error.message.include?(stage.to_s)

    Cleanup
    FileUtils.rm_rf(root)

    Where
    description               | present
    "the directory is absent" | false
    "only a subdirectory"     | true
  end

  test "a stage with several files is ambiguous, and the error lists them" do
    Given
    root = Pathname(Dir.mktmpdir("as-is-"))
    stage = root / "stage"
    stage.mkpath
    (stage / "a.zip").write("a")
    (stage / "b.zip").write("b")

    When
    Dev::Lifecycle::AsIsPackager.new.package(build("rspock"), stage, root / "store/rspock")

    Then
    error = raises(Dev::Lifecycle::AsIsPackager::AmbiguousStageError)
    error.message.include?("2 files (a.zip, b.zip)")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "as-is is a value and renders as its name" do
    Expect
    Dev::Lifecycle::AsIsPackager.new == Dev::Lifecycle::AsIsPackager.new
    Dev::Lifecycle::AsIsPackager.new.hash == Dev::Lifecycle::AsIsPackager.new.hash
    Dev::Lifecycle::AsIsPackager.new.to_s == "as-is"
  end
end
