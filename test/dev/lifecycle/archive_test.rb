# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "support/lifecycle_fixtures"
require "digest"
require "fileutils"
require "open3"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ArchiveTest < Minitest::Test
  include LifecycleFixtures

  FORM = Dev::Lifecycle::Archive::Form
  FORMAT = Dev::Lifecycle::Archive::Format

  # A shell whose pipeline stages report what a real `false` child did.
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

  test "the zip form archives the install's contents at the root, symlinks kept, as <archive>.zip" do
    Given "an install with a file, a nested file and a symlink"
    root = Pathname(Dir.mktmpdir("archive-"))
    install = root / "install"
    (install / "Binaries").mkpath
    (install / "Binaries/game.exe").write("exe")
    (install / "readme.txt").write("hi")
    File.symlink("readme.txt", install / "link.txt")
    archive = root / "store/cellbound-3d-win64-dev"

    When
    packed = Dev::Lifecycle::Archive.new.package(build("cellbound-3d-win64-dev"), install, archive)

    Then
    packed == Dev::Lifecycle::PackedArchive.new(archive: root / "store/cellbound-3d-win64-dev.zip")
    packed.name == "cellbound-3d-win64-dev.zip"
    !packed.split?
    packed.files == [packed.archive]
    listing = Open3.capture2("unzip", "-Z1", packed.archive.to_s).first.lines.map(&:chomp).sort
    listing == ["Binaries/", "Binaries/game.exe", "link.txt", "readme.txt"]
    Open3.capture2("unzip", "-Z", packed.archive.to_s).first.lines.grep(/link\.txt/).first.start_with?("l")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "the tar form writes <archive>.tar.zst that zstd and tar read back" do
    Given
    root = Pathname(Dir.mktmpdir("archive-"))
    install = root / "install"
    (install / "lib").mkpath
    (install / "lib/dev.rb").write("# dev")
    (install / "VERSION").write("0.8.0")
    archive = root / "store/dev-core"
    packager = Dev::Lifecycle::Archive.new(form: FORM::Tar.new)

    When
    packed = packager.package(build("rspock"), install, archive)

    Then
    packed == Dev::Lifecycle::PackedArchive.new(archive: root / "store/dev-core.tar.zst")
    packed.name == "dev-core.tar.zst"
    listing, = Open3.capture2("sh", "-c", "zstd -d -c #{packed.archive} | tar -tf -")
    listing.lines.map(&:chomp).sort == ["./", "./VERSION", "./lib/", "./lib/dev.rb"]
    packager.to_s == "archive (tar)"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "the split tar form writes numbered parts of at most the size plus a MANIFEST of their digests, the MANIFEST being the archive" do
    Given "an install larger than two parts"
    root = Pathname(Dir.mktmpdir("archive-"))
    install = root / "install"
    install.mkpath
    (install / "noise.bin").write(Random.new(7).bytes(5000))
    archive = root / "store/ue-toolchain"
    split = Dev::Lifecycle::ByteSize.parse("2KiB")
    packager = Dev::Lifecycle::Archive.new(form: FORM::Tar.new(split:))

    When
    packed = packager.package(build("rspock"), install, archive)

    Then "the MANIFEST first, the parts in order and within the size; the MANIFEST in sha256sum -c's form; " \
      "the parts concatenated are the archive the gh integration's reader consumes"
    packed.archive == root / "store/ue-toolchain.MANIFEST"
    packed.split?
    packed.parts.size >= 3
    packed.parts == packed.parts.size.times.map { |index| root / format("store/ue-toolchain.tar.zst.%02d", index) }
    packed.parts.all? { |part| part.size <= 2048 }
    packed.files == [packed.archive, *packed.parts]
    lines = packed.archive.read.lines.map(&:chomp)
    lines == packed.parts.map { |part| "#{Digest::SHA256.file(part).hexdigest}  #{part.basename}" }
    listing, = Open3.capture2("sh", "-c", "cat #{packed.parts.join(" ")} | zstd -d | tar -tf -")
    listing.lines.map(&:chomp).sort == ["./", "./noise.bin"]
    packager.to_s == "archive (tar, split 2KiB)"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "packaging again overwrites in place: a previous form's output does not survive" do
    Given "a split set and a zip from earlier packagings"
    root = Pathname(Dir.mktmpdir("archive-"))
    install = root / "install"
    install.mkpath
    (install / "a.txt").write("a")
    archive = root / "store/rspock"
    Dev::Lifecycle::Archive.new(form: FORM::Tar.new(split: Dev::Lifecycle::ByteSize.parse("1KiB"))).package(build("rspock"), install, archive)
    Dev::Lifecycle::Archive.new.package(build("rspock"), install, archive)

    When "the whole tar form is packaged over them"
    packed = Dev::Lifecycle::Archive.new(form: FORM::Tar.new).package(build("rspock"), install, archive)

    Then
    (root / "store").children.map { |path| path.basename.to_s } == ["rspock.tar.zst"]
    packed.archive == root / "store/rspock.tar.zst"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a missing install is refused before anything is written" do
    Given
    root = Pathname(Dir.mktmpdir("archive-"))

    When
    Dev::Lifecycle::Archive.new.package(build("rspock"), root / "missing", root / "store/rspock")

    Then
    raises Dev::Lifecycle::Archive::MissingInstallError
    !(root / "store").exist?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "an empty install is refused before anything is written" do
    Given
    root = Pathname(Dir.mktmpdir("archive-"))
    (root / "empty").mkpath

    When
    Dev::Lifecycle::Archive.new.package(build("rspock"), root / "empty", root / "store/rspock")

    Then
    raises Dev::Lifecycle::Archive::EmptyInstallError
    !(root / "store").exist?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a failed pipeline stage is reported by name with how it ended: #{form_name}" do
    Given
    root = Pathname(Dir.mktmpdir("archive-"))
    install = root / "install"
    install.mkpath
    (install / "a.txt").write("a")
    packager = Dev::Lifecycle::Archive.new(form: form, shell: FailingShell.new(fail_stage: 1))

    When
    packager.package(build("rspock"), install, root / "store/rspock")

    Then
    error = raises(Dev::Lifecycle::Archive::PackFailedError)
    error.message.include?(failed)
    error.message.include?("exited 1")

    Cleanup
    FileUtils.rm_rf(root)

    Where
    form_name | form                                                                        | failed
    "zip"     | Dev::Lifecycle::Archive::Form::Zip.new                                      | "zip of"
    "tar"     | Dev::Lifecycle::Archive::Form::Tar.new                                      | "`zstd`"
    "split"   | Dev::Lifecycle::Archive::Form::Tar.new(split: Dev::Lifecycle::ByteSize.parse("1KiB")) | "`zstd`"
  end

  test "Form.for is the one site of the split-needs-tar rule" do
    Expect
    FORM.for(format: FORMAT::Zip) == FORM::Zip.new
    FORM.for(format: FORMAT::Tar) == FORM::Tar.new
    FORM.for(format: FORMAT::Tar, split: Dev::Lifecycle::ByteSize.parse("2GiB")) ==
      FORM::Tar.new(split: Dev::Lifecycle::ByteSize.parse("2GiB"))
    FORM::Zip.new.extension == "zip"
    FORM::Tar.new.extension == "tar.zst"
    FORM::Tar.new(split: Dev::Lifecycle::ByteSize.parse("2GiB")).extension == "MANIFEST"
    FORM::Tar.new != FORM::Zip.new
  end

  test "a split zip is refused: split needs the tar format" do
    When
    FORM.for(format: FORMAT::Zip, split: Dev::Lifecycle::ByteSize.parse("2GiB"))

    Then
    error = raises(Dev::Lifecycle::Archive::SplitNeedsTarError)
    error.message.include?("format: tar")
  end

  test "Format parses its ids" do
    Expect
    FORMAT.parse("zip") == FORMAT::Zip
    FORMAT.parse("tar") == FORMAT::Tar
    FORMAT.ids == ["zip", "tar"]
  end

  test "Format refuses an id outside its set, listing it" do
    When
    FORMAT.parse("7z")

    Then
    error = raises(Dev::Lifecycle::Archive::UnknownFormatError)
    error.message.include?("zip, tar")
  end

  test "archives are values over their form" do
    Expect
    Dev::Lifecycle::Archive.new == Dev::Lifecycle::Archive.new(form: FORM::Zip.new)
    Dev::Lifecycle::Archive.new != Dev::Lifecycle::Archive.new(form: FORM::Tar.new)
    Dev::Lifecycle::Archive.new.to_s == "archive"
    Dev::Lifecycle::Archive.new.hash == Dev::Lifecycle::Archive.new.hash
  end
end
