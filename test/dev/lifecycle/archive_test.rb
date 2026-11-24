# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "support/lifecycle_fixtures"
require "support/shown_publisher"
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

  test "the zip form archives the stage's contents at the root, symlinks kept, as <archive>.zip" do
    Given "a stage with a file, a nested file and a symlink"
    root = Pathname(Dir.mktmpdir("archive-"))
    stage = root / "stage"
    (stage / "Binaries").mkpath
    (stage / "Binaries/game.exe").write("exe")
    (stage / "readme.txt").write("hi")
    File.symlink("readme.txt", stage / "link.txt")
    archive = root / "store/cellbound-3d-win64-dev"

    When
    packed = Dev::Lifecycle::Archive.new.package(build("cellbound-3d-win64-dev"), stage, archive)

    Then
    packed == Dev::Lifecycle::PackedArchive.new(archive: root / "store/cellbound-3d-win64-dev.zip")
    packed.name == "cellbound-3d-win64-dev.zip"
    !packed.split?
    Dev::Lifecycle::Archive.new.deprecations == []
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
    stage = root / "stage"
    (stage / "lib").mkpath
    (stage / "lib/dev.rb").write("# dev")
    (stage / "VERSION").write("0.8.0")
    archive = root / "store/dev-core"
    packager = Dev::Lifecycle::Archive.new(form: FORM::Tar.new)

    When
    packed = packager.package(build("rspock"), stage, archive)

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
    Given "a stage larger than two parts"
    root = Pathname(Dir.mktmpdir("archive-"))
    stage = root / "stage"
    stage.mkpath
    (stage / "noise.bin").write(Random.new(7).bytes(5000))
    archive = root / "store/ue-toolchain"
    split = Dev::Lifecycle::ByteSize.parse("2KiB")
    packager = Dev::Lifecycle::Archive.new(form: FORM::Tar.new(split:))

    When
    packed = packager.package(build("rspock"), stage, archive)

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

  test "a files: selection archives the selected files at their stage paths, directory entries and symlinks as a whole archive has them, and leaves the stage alone" do
    Given "a stage with a tool tree, its lock and a doc; a selection of the tree without its scratch"
    root = Pathname(Dir.mktmpdir("archive-"))
    stage = root / "stage"
    (stage / "bin").mkpath
    (stage / "lib/scratch").mkpath
    (stage / "deploy/d3mlabs").mkpath
    (stage / "bin/dev").write("#!/bin/sh\n")
    (stage / "bin/dev").chmod(0o755)
    (stage / "lib/dev.rb").write("# dev")
    (stage / "lib/scratch/tmp.rb").write("# tmp")
    (stage / "deploy/d3mlabs/config.yml").write("org: d3mlabs")
    (stage / "deps.lock").write("lock")
    (stage / "VERSION").write("1.0.0")
    File.symlink("dev.rb", stage / "lib/alias.rb")
    files = Dev::Lifecycle::FileSelection.parse(["bin", "lib", "!lib/scratch", "deploy/d3mlabs/config.yml", "VERSION"])
    packager = Dev::Lifecycle::Archive.new(files:)

    When
    packed = packager.package(build("rspock"), stage, root / "store/dev-core")

    Then "the zip holds the selection at stage paths, with the directory entries a whole archive has"
    packed.archive == root / "store/dev-core.zip"
    listing = Open3.capture2("unzip", "-Z1", packed.archive.to_s).first.lines.map(&:chomp).sort
    listing == [
      "VERSION", "bin/", "bin/dev", "deploy/", "deploy/d3mlabs/", "deploy/d3mlabs/config.yml",
      "lib/", "lib/alias.rb", "lib/dev.rb",
    ]
    Open3.capture2("unzip", "-Z", packed.archive.to_s).first.lines.grep(/lib\/alias\.rb/).first.start_with?("l")
    Open3.capture2("unzip", "-Z", packed.archive.to_s).first.lines.grep(/bin\/dev/).first.start_with?("-rwxr-xr-x")
    packager.to_s == "archive, files: bin lib !lib/scratch deploy/d3mlabs/config.yml VERSION"
    # The stage is as it was: the selection is read, not carved.
    (stage / "deps.lock").exist?
    (stage / "lib/scratch/tmp.rb").exist?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a files: selection in the tar form lists the selected files only" do
    Given
    root = Pathname(Dir.mktmpdir("archive-"))
    stage = root / "stage"
    (stage / "lib").mkpath
    (stage / "lib/dev.rb").write("# dev")
    (stage / "VERSION").write("0.8.0")
    (stage / "Gemfile").write("")
    packager = Dev::Lifecycle::Archive.new(form: FORM::Tar.new, files: Dev::Lifecycle::FileSelection.parse(["lib", "VERSION"]))

    When
    packed = packager.package(build("rspock"), stage, root / "store/dev-core")

    Then
    listing, = Open3.capture2("sh", "-c", "zstd -d -c #{packed.archive} | tar -tf -")
    listing.lines.map(&:chomp).sort == ["./", "./VERSION", "./lib/", "./lib/dev.rb"]
    packager.to_s == "archive (tar), files: lib VERSION"

    Cleanup
    FileUtils.rm_rf(root)
  end

  def gh_channel
    Dev::Lifecycle::Channel.new(
      name: "gh", accepts: [Dev::Lifecycle::BuildPattern.new(target: gem_target)],
      publisher: Dev::Lifecycle::PublisherSpec::Integration.new(name: "gh"),
    )
  end

  def acceptance(publisher)
    Dev::Lifecycle::Acceptance.new(acceptors: { gh_channel => publisher })
  end

  test "the destinations are shown the selection — the tree as it ships — not the stage, before the archive is written" do
    Given "a stage whose files: leaves the lock out"
    root = Pathname(Dir.mktmpdir("archive-"))
    stage = root / "stage"
    (stage / "exe").mkpath
    (stage / "exe/ai-flow").write("#!/usr/bin/env ruby\n")
    (stage / "dependencies.rb").write("manifest")
    (stage / "deps.lock").write("lock")
    publisher = ShownPublisher.new
    packager = Dev::Lifecycle::Archive.new(files: Dev::Lifecycle::FileSelection.parse(["exe", "dependencies.rb"]))

    When
    packed = packager.package(build("rspock"), stage, root / "store/ai-flow", acceptance: acceptance(publisher))

    Then "the publisher saw the two selected entries under the channel, not the stage, and the archive followed"
    publisher.shown.map(&:entries) == [["dependencies.rb", "exe"]]
    publisher.shown.map(&:channel) == [gh_channel]
    publisher.shown.first.tree != stage
    packed.archive.file?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "with no files:, the stage itself is what the destinations are shown" do
    Given
    root = Pathname(Dir.mktmpdir("archive-"))
    stage = root / "stage"
    stage.mkpath
    (stage / "a.txt").write("a")
    publisher = ShownPublisher.new

    When
    Dev::Lifecycle::Archive.new.package(build("rspock"), stage, root / "store/rspock", acceptance: acceptance(publisher))

    Then
    publisher.shown.map(&:tree) == [stage]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a destination's refusal is the packager's failure, raised as the publisher words it, with the previous archive left in place" do
    Given "an earlier archive, and a publisher that refuses"
    root = Pathname(Dir.mktmpdir("archive-"))
    stage = root / "stage"
    stage.mkpath
    (stage / "a.txt").write("a")
    archive = root / "store/rspock"
    Dev::Lifecycle::Archive.new.package(build("rspock"), stage, archive)
    before = (root / "store/rspock.zip").read

    When
    Dev::Lifecycle::Archive.new.package(build("rspock"), stage, archive, acceptance: acceptance(ShownPublisher.new(refuse: true)))

    Then
    error = raises(ShownPublisher::RefusedError)
    error.message == "gh refuses the tree"
    (root / "store/rspock.zip").read == before

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a files: selection that selects nothing is refused with the patterns named, before anything is written" do
    Given
    root = Pathname(Dir.mktmpdir("archive-"))
    stage = root / "stage"
    stage.mkpath
    (stage / "game.exe").write("exe")
    packager = Dev::Lifecycle::Archive.new(files: Dev::Lifecycle::FileSelection.parse(["bin", "lib"]))

    When
    packager.package(build("rspock"), stage, root / "store/rspock")

    Then
    error = raises(Dev::Lifecycle::FileSelection::EmptySelectionError)
    error.message.include?("files: bin lib selects nothing")
    !(root / "store").exist?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "packaging again overwrites in place: a previous form's output does not survive" do
    Given "a split set and a zip from earlier packagings"
    root = Pathname(Dir.mktmpdir("archive-"))
    stage = root / "stage"
    stage.mkpath
    (stage / "a.txt").write("a")
    archive = root / "store/rspock"
    Dev::Lifecycle::Archive.new(form: FORM::Tar.new(split: Dev::Lifecycle::ByteSize.parse("1KiB"))).package(build("rspock"), stage, archive)
    Dev::Lifecycle::Archive.new.package(build("rspock"), stage, archive)

    When "the whole tar form is packaged over them"
    packed = Dev::Lifecycle::Archive.new(form: FORM::Tar.new).package(build("rspock"), stage, archive)

    Then
    (root / "store").children.map { |path| path.basename.to_s } == ["rspock.tar.zst"]
    packed.archive == root / "store/rspock.tar.zst"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a missing stage is refused before anything is written" do
    Given
    root = Pathname(Dir.mktmpdir("archive-"))

    When
    Dev::Lifecycle::Archive.new.package(build("rspock"), root / "missing", root / "store/rspock")

    Then
    raises Dev::Lifecycle::Archive::MissingDirectoryError
    !(root / "store").exist?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "an empty stage is refused before anything is written" do
    Given
    root = Pathname(Dir.mktmpdir("archive-"))
    (root / "empty").mkpath

    When
    Dev::Lifecycle::Archive.new.package(build("rspock"), root / "empty", root / "store/rspock")

    Then
    raises Dev::Lifecycle::Archive::EmptyDirectoryError
    !(root / "store").exist?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a failed pipeline stage is reported by name with how it ended: #{form_name}" do
    Given
    root = Pathname(Dir.mktmpdir("archive-"))
    stage = root / "stage"
    stage.mkpath
    (stage / "a.txt").write("a")
    packager = Dev::Lifecycle::Archive.new(form: form, shell: FailingShell.new(fail_stage: 1))

    When
    packager.package(build("rspock"), stage, root / "store/rspock")

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

  test "archives are values over their form and their selection" do
    Expect
    Dev::Lifecycle::Archive.new == Dev::Lifecycle::Archive.new(form: FORM::Zip.new)
    Dev::Lifecycle::Archive.new == Dev::Lifecycle::Archive.new(files: Dev::Lifecycle::FileSelection.all)
    Dev::Lifecycle::Archive.new != Dev::Lifecycle::Archive.new(form: FORM::Tar.new)
    Dev::Lifecycle::Archive.new != Dev::Lifecycle::Archive.new(files: Dev::Lifecycle::FileSelection.parse(["bin"]))
    Dev::Lifecycle::Archive.new.to_s == "archive"
    Dev::Lifecycle::Archive.new.hash == Dev::Lifecycle::Archive.new.hash
  end
end
