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

  # dev's own Gemfile.lock shape: the gem under `remote: .` with
  # dependencies six spaces in, and a sibling gem at the same number that
  # must not move.
  GEMFILE_LOCK = <<~LOCK
    PATH
      remote: .
      specs:
        dev (1.1.0)
          cli-ui (~> 2.0)
          sorbet-runtime (~> 0.6)

    GEM
      remote: https://rubygems.org/
      specs:
        other (1.1.0)
        cli-ui (2.7.0)
  LOCK

  test "a gem's Gemfile.lock mirrors VERSION: the bump rewrites the PATH spec's version and nothing else" do
    Given
    root = Pathname(Dir.mktmpdir("project-version-"))
    (root / "VERSION").write("1.1.0\n")
    (root / "Gemfile.lock").write(GEMFILE_LOCK)

    When
    files = Dev::Lifecycle::ProjectVersion.files(root, current: "1.1.0")
    Dev::Lifecycle::ProjectVersion.write(root, "1.2.0")

    Then
    files == ["VERSION", "Gemfile.lock"]
    (root / "Gemfile.lock").read == GEMFILE_LOCK.sub("dev (1.1.0)", "dev (1.2.0)")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a project whose #{what} keeps the bump to VERSION alone" do
    Given
    root = Pathname(Dir.mktmpdir("project-version-"))
    (root / "VERSION").write("1.1.0\n")
    (root / "Gemfile.lock").write(lock) if lock

    When
    files = Dev::Lifecycle::ProjectVersion.files(root, current: "1.1.0")
    Dev::Lifecycle::ProjectVersion.write(root, "1.2.0")

    Then
    files == ["VERSION"]
    (root / "VERSION").read == "1.2.0\n"
    lock.nil? || (root / "Gemfile.lock").read == lock

    Cleanup
    FileUtils.rm_rf(root)

    Where
    what                                            | lock
    "Gemfile.lock is absent"                        | nil
    "Gemfile.lock has no PATH section"              | GEMFILE_LOCK.sub(/\APATH.*?\n\n/m, "")
    "Gemfile.lock's PATH gem is at another version" | GEMFILE_LOCK.sub("dev (1.1.0)", "dev (1.0.0)")
  end
end
