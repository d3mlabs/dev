# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/gemfile_lock"

transform!(RSpock::AST::Transformation)
class Dev::GemfileLockTest < Minitest::Test
  # dev's own lock shape: the project's gem under `remote: .` with its
  # dependencies six spaces in, a sibling gem at the same number that must
  # never be touched, and bundler's CHECKSUMS section naming every gem a
  # second time — the path gem without a digest.
  LOCK = <<~LOCK
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

  NO_PATH_SECTION = LOCK.sub(/\APATH.*?\n\n/m, "")
  NO_CHECKSUMS = LOCK.sub(/\n\nCHECKSUMS\n.*\z/m, "\n")

  test "the own gem is the one under PATH / remote: . — its name and version; a lock without one has none" do
    Expect
    Dev::GemfileLock.new(text).own_gem == gem
    Dev::GemfileLock.new(text).own_version == version

    Where
    text            | gem   | version
    LOCK            | "dev" | "1.1.0"
    NO_CHECKSUMS    | "dev" | "1.1.0"
    NO_PATH_SECTION | nil   | nil
  end

  test "with_own_version moves the own gem's spec line and its CHECKSUMS entry, and nothing else — #{what}" do
    Expect "both `dev (1.1.0)` lines moved where present; `other (1.1.0)` twice did not"
    Dev::GemfileLock.new(text).with_own_version("1.2.0") == text.gsub("dev (1.1.0)", "dev (1.2.0)")

    Where
    what                 | text
    "bundler ≥ 2.6"      | LOCK
    "without CHECKSUMS"  | NO_CHECKSUMS
  end

  test "with_own_version on a lock with no own gem is refused: there is nothing of the project's to move" do
    When
    Dev::GemfileLock.new(NO_PATH_SECTION).with_own_version("1.2.0")

    Then
    raises(Dev::GemfileLock::NoOwnGemError)
  end

  test "without_own_version is the same text for two locks that differ only in the own gem's version (dev#527)" do
    Expect
    Dev::GemfileLock.new(LOCK).without_own_version == Dev::GemfileLock.new(LOCK.gsub("dev (1.1.0)", "dev (1.2.0)")).without_own_version
  end

  test "without_own_version still tells two locks apart that differ anywhere else — #{what}" do
    Expect
    Dev::GemfileLock.new(LOCK).without_own_version != Dev::GemfileLock.new(changed).without_own_version

    Where
    what                                  | changed
    "a sibling gem at the same number"    | LOCK.sub("other (1.1.0)\n    cli-ui", "other (1.2.0)\n    cli-ui")
    "a dependency of the own gem"         | LOCK.sub("cli-ui (~> 2.0)", "cli-ui (~> 3.0)")
    "a locked gem's version"              | LOCK.gsub("cli-ui (2.7.0)", "cli-ui (2.8.0)")
    "the own gem renamed"                 | LOCK.gsub("dev (1.1.0)", "dev2 (1.1.0)")
  end

  test "without_own_version of a lock with no own gem is the lock" do
    Expect
    Dev::GemfileLock.new(NO_PATH_SECTION).without_own_version == NO_PATH_SECTION
  end
end
