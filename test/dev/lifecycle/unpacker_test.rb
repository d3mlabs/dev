# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "support/lifecycle_fixtures"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::UnpackerTest < Minitest::Test
  include LifecycleFixtures

  FORM = Dev::Lifecycle::Archive::Form

  # A shell whose children all fail, as a real `false` does.
  class FailingShell < Dev::Lifecycle::Shell
    def initialize(fail_stage:)
      super()
      @fail_stage = fail_stage
    end

    def pipeline(commands, chdir:)
      _ = chdir
      commands.each_index.map { |index| child_status(index == @fail_stage ? "false" : "true") }
    end

    def run(argv, chdir:, env: {})
      _ = [argv, chdir, env]
      child_status("false")
    end

    private

    def child_status(program)
      _pid, status = Process.wait2(Process.spawn(program))
      status
    end
  end

  def setup
    @root = Pathname(Dir.mktmpdir("unpacker-"))
    @install = @root / "install"
    (@install / "Binaries").mkpath
    (@install / "Binaries/game.exe").write("exe")
    (@install / "readme.txt").write("hi " * 700)
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def packed_with(form)
    Dev::Lifecycle::Archive.new(form:).package(build("cellbound-3d-win64-dev"), @install, @root / "store/cellbound-3d-win64-dev").archive
  end

  def contents(dir)
    Dir.glob("**/*", base: dir).sort.to_h { |relative| [relative, (dir / relative).file? ? (dir / relative).read : :dir] }
  end

  test "unpack restores every form Archive writes into the directory, which it returns" do
    Given "an archive in a #{label} form"
    archive = packed_with(form)
    into = @root / "depots/1001"

    When
    returned = Dev::Lifecycle::Unpacker.new.unpack(archive, into:)

    Then "the directory holds exactly the install's contents and the archive is untouched"
    returned == into
    contents(into) == contents(@install)
    archive.file?

    Where
    label   | form
    "zip"   | FORM::Zip.new
    "tar"   | FORM::Tar.new
    "split" | FORM::Tar.new(split: Dev::Lifecycle::ByteSize.parse("1KiB"))
  end

  test "unpack replaces the directory: a file from a previous unpack never rides along" do
    Given "a destination holding a stale file"
    archive = packed_with(FORM::Zip.new)
    into = @root / "depots/1001"
    (into / "stale").mkpath
    (into / "stale/old.dll").write("old")

    When
    Dev::Lifecycle::Unpacker.new.unpack(archive, into:)

    Then
    contents(into) == contents(@install)
  end

  test "unpack refuses an archive that is not there" do
    When
    Dev::Lifecycle::Unpacker.new.unpack(@root / "store/missing.zip", into: @root / "depots/1")

    Then
    error = raises Dev::Lifecycle::Unpacker::MissingArchiveError
    error.message == "no archive at #{@root}/store/missing.zip"
  end

  test "unpack refuses an extension Archive never writes" do
    Given "a file in no known form"
    (@root / "store").mkpath
    archive = @root / "store/cellbound-3d-win64-dev.7z"
    archive.write("?")

    When
    Dev::Lifecycle::Unpacker.new.unpack(archive, into: @root / "depots/1")

    Then
    error = raises Dev::Lifecycle::Unpacker::UnknownArchiveFormatError
    error.message == "cellbound-3d-win64-dev.7z: not an archive dev packs (.zip, .tar.zst or a split set's .MANIFEST)"
  end

  test "a failing unzip is reported with its status" do
    Given "a zip and a shell whose children fail"
    archive = packed_with(FORM::Zip.new)

    When
    Dev::Lifecycle::Unpacker.new(shell: FailingShell.new(fail_stage: 0)).unpack(archive, into: @root / "depots/1")

    Then
    error = raises Dev::Lifecycle::Unpacker::UnpackFailedError
    error.message == "unzip of #{archive} exited 1"
  end

  test "a failing tar pipeline names the stage that failed" do
    Given "a tar and a shell whose stage #{stage} fails"
    archive = packed_with(FORM::Tar.new)

    When
    Dev::Lifecycle::Unpacker.new(shell: FailingShell.new(fail_stage: stage)).unpack(archive, into: @root / "depots/1")

    Then
    error = raises Dev::Lifecycle::Unpacker::UnpackFailedError
    error.message == "unpacking #{archive}: `#{program}` exited 1"

    Where
    stage | program
    0     | "cat"
    1     | "zstd"
    2     | "tar"
  end
end
