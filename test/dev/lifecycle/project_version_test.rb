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

  test "next bumps one part of a semver and zeroes the ones after it: #{current} #{part.serialize} → #{expected} (dev#525)" do
    Expect
    Dev::Lifecycle::ProjectVersion.next(current, part) == expected

    Where
    current  | part                                        | expected
    "1.1.0"  | Dev::Lifecycle::ProjectVersion::Part::Patch | "1.1.1"
    "1.1.9"  | Dev::Lifecycle::ProjectVersion::Part::Minor | "1.2.0"
    "1.1.9"  | Dev::Lifecycle::ProjectVersion::Part::Major | "2.0.0"
    "0.8.0"  | Dev::Lifecycle::ProjectVersion::Part::Patch | "0.8.1"
  end

  test "next refuses a version that is not three numbers — there is no patch of #{current.inspect} to bump" do
    When
    Dev::Lifecycle::ProjectVersion.next(current, Dev::Lifecycle::ProjectVersion::Part::Patch)

    Then
    error = raises(Dev::Lifecycle::ProjectVersion::NotSemverError)
    error.message == "#{current.inspect} is not major.minor.patch — give the version to release"

    Where
    current      | _
    "1.1"        | nil
    "3.0.0-rc.1" | nil
    "v1.1.0"     | nil
  end

  test "Part reads the bump words of `dev release`: #{word.inspect} → #{part.inspect}" do
    Expect
    Dev::Lifecycle::ProjectVersion::Part.try_deserialize(word) == part

    Where
    word    | part
    "major" | Dev::Lifecycle::ProjectVersion::Part::Major
    "minor" | Dev::Lifecycle::ProjectVersion::Part::Minor
    "patch" | Dev::Lifecycle::ProjectVersion::Part::Patch
    "1.2.0" | nil
    "Minor" | nil
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
  # dependencies six spaces in, a sibling gem at the same number that must
  # not move, and bundler's (≥ 2.6) CHECKSUMS section recording every gem
  # a second time — the path gem without a digest (dev#521).
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

    CHECKSUMS
      cli-ui (2.7.0) sha256=e36147f2e8088796b996f0560f577bd1599f2b6aa3c374fe09fff59af5589c35
      dev (1.1.0)
      other (1.1.0) sha256=0000000000000000000000000000000000000000000000000000000000000000
  LOCK

  # The same lock as an older bundler writes it: no CHECKSUMS section.
  GEMFILE_LOCK_WITHOUT_CHECKSUMS = GEMFILE_LOCK.sub(/\n\nCHECKSUMS\n.*\z/m, "\n")

  test "a gem's Gemfile.lock mirrors VERSION: the bump rewrites the gem's PATH spec and its CHECKSUMS entry, and nothing else" do
    Given
    root = Pathname(Dir.mktmpdir("project-version-"))
    (root / "VERSION").write("1.1.0\n")
    (root / "Gemfile.lock").write(GEMFILE_LOCK)

    When
    files = Dev::Lifecycle::ProjectVersion.files(root, current: "1.1.0")
    Dev::Lifecycle::ProjectVersion.write(root, "1.2.0")

    Then "both `dev (1.1.0)` lines moved; `other (1.1.0)` twice did not"
    files == ["VERSION", "Gemfile.lock"]
    (root / "Gemfile.lock").read == GEMFILE_LOCK.gsub("dev (1.1.0)", "dev (1.2.0)")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a lock without a CHECKSUMS section (an older bundler) mirrors through its PATH spec alone" do
    Given
    root = Pathname(Dir.mktmpdir("project-version-"))
    (root / "VERSION").write("1.1.0\n")
    (root / "Gemfile.lock").write(GEMFILE_LOCK_WITHOUT_CHECKSUMS)

    When
    files = Dev::Lifecycle::ProjectVersion.files(root, current: "1.1.0")
    Dev::Lifecycle::ProjectVersion.write(root, "1.2.0")

    Then
    files == ["VERSION", "Gemfile.lock"]
    (root / "Gemfile.lock").read == GEMFILE_LOCK_WITHOUT_CHECKSUMS.sub("dev (1.1.0)", "dev (1.2.0)")

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
