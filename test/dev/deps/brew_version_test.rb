# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/brew_version"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BrewVersionTest < Minitest::Test
  BrewVersion = Dev::Deps::BrewVersion

  test "#{left} <=> #{right} is #{expected} under Homebrew's rules" do
    When "comparing"
    result = BrewVersion.new(left) <=> BrewVersion.new(right)

    Then
    result == expected

    Where
    left          | right         | expected
    "3.11.4_1"    | "3.11.4"      | 1
    "3.11.4_2"    | "3.11.4_1"    | 1
    "3.11.10"     | "3.11.4"      | 1
    "1.0"         | "1.0.0"       | 0
    "1.0"         | "1.0.1"       | -1
    "1.0r3"       | "1.0"         | 1
    "1.0r3"       | "1.0r10"      | -1
    "1.0p1"       | "1.0"         | 1
    "1.0p1"       | "1.0.1"       | -1
    "1.0.post1"   | "1.0"         | 1
    "1.0.post1"   | "1.0p1"       | 1
    "1.0.0-beta"  | "1.0.0"       | -1
    "1.0.0-alpha" | "1.0.0-beta"  | -1
    "1.0.0-beta"  | "1.0.0-pre"   | -1
    "1.0.0-pre"   | "1.0.0-rc1"   | -1
    "1.0.0-rc1"   | "1.0.0-rc2"   | -1
    "1.0a1"       | "1.0b1"       | -1
    "2024-01-15"  | "2024-02-01"  | -1
    "2024-01-15"  | "2023-12-31"  | 1
    "2.1p2"       | "2.1p10"      | -1
  end

  test "sorts every shape brew writes" do
    Given "versions out of order"
    versions = ["3.11.4_1", "3.11.4", "3.11.10", "3.11.4_2", "3.11.5-rc1", "3.11.5"].map { |v| BrewVersion.new(v) }

    When "sorting"
    sorted = versions.sort.map(&:to_s)

    Then
    sorted == ["3.11.4", "3.11.4_1", "3.11.4_2", "3.11.5-rc1", "3.11.5", "3.11.10"]
  end

  test "to_s is the version as written" do
    Expect
    BrewVersion.new("3.11.4_1").to_s == "3.11.4_1"
  end

  test "#{version.inspect} is not a brew version" do
    When
    BrewVersion.new(version)

    Then
    raises BrewVersion::InvalidVersionError

    Where
    version
    ""
    "HEAD"
    "v1.2.3"
  end
end
