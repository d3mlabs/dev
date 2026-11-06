# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ProjectVersionTest < Minitest::Test
  test "a VERSION file's first line is the project's semver, whitespace trimmed" do
    Given
    root = Pathname(Dir.mktmpdir("project-version-"))
    (root / "VERSION").write(contents)

    Expect
    Dev::Lifecycle::ProjectVersion.read(root) == expected

    Cleanup
    FileUtils.rm_rf(root)

    Where
    contents              | expected
    "1.2.0\n"             | "1.2.0"
    "  0.7.2  \n"         | "0.7.2"
    "3.0.0-rc.1\n# note"  | "3.0.0-rc.1"
  end

  test "a project with #{what} stamps the default semver" do
    Given
    root = Pathname(Dir.mktmpdir("project-version-"))
    (root / "VERSION").write(contents) if contents

    Expect
    Dev::Lifecycle::ProjectVersion.read(root) == Dev::Lifecycle::BuildId::DEFAULT_SEMVER

    Cleanup
    FileUtils.rm_rf(root)

    Where
    what                   | contents
    "no VERSION file"      | nil
    "an empty VERSION"     | ""
    "a blank VERSION line" | "  \n"
  end

  test "declared is the version a project keeps in source" do
    Given
    root = Pathname(Dir.mktmpdir("project-version-"))
    (root / "VERSION").write("1.2.0\n")

    Expect
    Dev::Lifecycle::ProjectVersion.declared(root) == "1.2.0"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "declared is nil for a project with #{what}: it keeps no version in source" do
    Given
    root = Pathname(Dir.mktmpdir("project-version-"))
    (root / "VERSION").write(contents) if contents

    Expect
    Dev::Lifecycle::ProjectVersion.declared(root).nil?

    Cleanup
    FileUtils.rm_rf(root)

    Where
    what                   | contents
    "no VERSION file"      | nil
    "a blank VERSION"      | " \n"
  end

  test "write replaces the version in source with one line, which read and declared then answer" do
    Given
    root = Pathname(Dir.mktmpdir("project-version-"))
    (root / "VERSION").write("1.1.0\n")

    When
    Dev::Lifecycle::ProjectVersion.write(root, "1.2.0")

    Then
    (root / "VERSION").read == "1.2.0\n"
    Dev::Lifecycle::ProjectVersion.read(root) == "1.2.0"

    Cleanup
    FileUtils.rm_rf(root)
  end
end
