# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/pack_command"
require "dev/lifecycle"
require "fileutils"
require "open3"
require "pathname"
require "stringio"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::PackCommandTest < Minitest::Test
  include SorbetHelper

  test "pack is hidden plumbing for package: scripts, declaring its three flags" do
    Given
    command = Dev::Builtins::PackCommand.new

    Expect
    command.hidden?
    !command.staleness_exempt?
    !command.stamps?
    command.category == Dev::Command::Category::Workflow
    command.flags.map(&:name) == ["--out", "--format", "--split"]
    command.flags.all?(&:takes_value?)
  end

  test "pack DIR zips the directory beside the caller as <name>.zip and prints the file" do
    Given "a directory to archive, run from a working directory"
    root = Pathname(Dir.mktmpdir("pack-"))
    (root / "install").mkpath
    (root / "install/game.txt").write("game")
    out = StringIO.new
    command = Dev::Builtins::PackCommand.new(out:)

    When
    Dir.chdir(root) { command.call(args: parsed_args(command, ["install"]), context: build_context) }

    Then
    (root / "install.zip").file?
    out.string == "#{(root / "install.zip").realpath}\n"
    Open3.capture2("unzip", "-Z1", (root / "install.zip").to_s).first.lines.map(&:chomp) == ["game.txt"]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "--out names the stem — a package: script's DEV_ARTIFACT — and the flags choose the form: #{words.join(" ")}" do
    Given
    root = Pathname(Dir.mktmpdir("pack-"))
    (root / "install").mkpath
    (root / "install/payload.bin").write(Random.new(3).bytes(3000))
    out = StringIO.new
    command = Dev::Builtins::PackCommand.new(out:)
    argv = [(root / "install").to_s, "--out", (root / "store/dev-core").to_s, *words]

    When
    command.call(args: parsed_args(command, argv), context: build_context)

    Then
    printed = out.string.lines.map(&:chomp)
    printed.first == (root / "store/#{first}").to_s
    printed.size >= count
    printed.all? { |file| Pathname(file).file? }

    Cleanup
    FileUtils.rm_rf(root)

    Where
    words                       | first                | count
    []                          | "dev-core.zip"       | 1
    ["--format", "zip"]         | "dev-core.zip"       | 1
    ["--format", "tar"]         | "dev-core.tar.zst"   | 1
    ["--split", "1KiB"]         | "dev-core.MANIFEST"  | 3
    ["--format=tar", "--split", "2KiB"] | "dev-core.MANIFEST" | 2
  end

  test "the form is built once per call over the flags, through the factory" do
    Given
    root = Pathname(Dir.mktmpdir("pack-"))
    (root / "install").mkpath
    (root / "install/a").write("a")
    forms = []
    archive = Dev::Lifecycle::Archive.new(form: Dev::Lifecycle::Archive::Form::Zip.new)
    factory = lambda do |form|
      forms << form
      archive
    end
    command = Dev::Builtins::PackCommand.new(archive_factory: factory, out: StringIO.new)

    When
    argv = [(root / "install").to_s, "--out", (root / "out").to_s, "--split", "2GiB"]
    command.call(args: parsed_args(command, argv), context: build_context)

    Then
    forms == [Dev::Lifecycle::Archive::Form::Tar.new(split: Dev::Lifecycle::ByteSize.parse("2GiB"))]
    (root / "out.zip").file?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "exactly one DIR is required: #{words.inspect}" do
    Given
    command = Dev::Builtins::PackCommand.new(out: StringIO.new)

    When
    command.call(args: parsed_args(command, words), context: build_context)

    Then
    error = raises(Dev::Builtins::PackCommand::UsageError)
    error.message == Dev::Builtins::PackCommand::USAGE

    Where
    words
    []
    ["a", "b"]
  end

  test "a malformed form flag surfaces as the form's own error: #{words.join(" ")}" do
    Given
    command = Dev::Builtins::PackCommand.new(out: StringIO.new)

    When
    command.call(args: parsed_args(command, ["dir", *words]), context: build_context)

    Then
    raises error_class

    Where
    words                                | error_class
    ["--format", "7z"]                   | Dev::Lifecycle::Archive::UnknownFormatError
    ["--split", "2GB"]                   | Dev::Lifecycle::ByteSize::InvalidByteSizeError
    ["--format", "zip", "--split", "1GiB"] | Dev::Lifecycle::Archive::SplitNeedsTarError
  end

  private

  def build_context
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Ui),
      project: Dev::ProjectContext.new(name: "TestProject", root: Pathname("/tmp/pack-test")),
    )
  end
end
