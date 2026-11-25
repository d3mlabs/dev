# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/package_version"
require "dev/deps/requirement"
require "dev/deps/semver_scheme"

transform!(RSpock::AST::Transformation)
class Dev::Deps::SemverSchemeTest < Minitest::Test
  Requirement = Dev::Deps::Requirement

  def scheme
    Dev::Deps::SemverScheme.new
  end

  def pv(version)
    Dev::Deps::PackageVersion.new(version: version)
  end

  test "#{version} against #{expression.inspect} is #{expected}" do
    When "evaluating dev's requirement under semver ordering"
    result = scheme.satisfies?(pv(version), Requirement.parse(expression))

    Then
    result == expected

    Where
    version       | expression          | expected
    "3.12.0"      | "~3.12.0"           | true
    "3.12.9"      | "~3.12.0"           | true
    "3.13.0"      | "~3.12.0"           | false
    "3.13.2"      | "^3.12"             | true
    "4.0.0"       | "^3.12"             | false
    "3.11.9"      | "^3.12"             | false
    "2.5.0"       | ">= 1.0.0, < 3.0.0" | true
    "3.0.0"       | ">= 1.0.0, < 3.0.0" | false
    "1.0.0"       | "1.0.0"             | true
    "1.0.1"       | "1.0.0"             | false
    "1.0.0-rc.1"  | ">= 1.0.0"          | false
    "1.0.0"       | "> 1.0.0-rc.1"      | true
    "1.0.0"       | "<= 1.0.0"          | true
    "1.0.1"       | "<= 1.0.0"          | false
  end

  test "prerelease #{version} against #{expression.inspect} is #{expected}, as node-semver reads it" do
    When "evaluating a prerelease the comparators alone would admit"
    result = scheme.satisfies?(pv(version), Requirement.parse(expression))

    Then "a prerelease is a candidate only where a term names a prerelease of its own release"
    result == expected

    Where
    version       | expression          | expected
    "2.0.0-rc.1"  | "^1"                | false
    "1.5.0-beta"  | "^1"                | false
    "1.0.0-rc.1"  | ">=1.0.0-0"         | true
    "1.0.0-rc.1"  | ">=1.0.0-0 <2.0.0"  | true
    "2.0.0-rc.1"  | ">=1.0.0-0"         | false
    "1.0.0-rc.2"  | "^1.0.0-rc.1"       | true
    "1.0.0-rc.2"  | "~1.0.0-rc.1"       | true
    "1.1.0-rc.1"  | "^1.0.0-rc.1"       | false
  end

  test "the range SMR writes (#{range.inspect}) reads as upstream reads it" do
    When "evaluating the range SMR wrote"
    result = scheme.satisfies?(pv(version), Requirement.parse(range))

    Then
    result == expected

    Where
    version       | range              | expected
    "3.12.0"      | "^3.12.0"          | true
    "3.13.2"      | "^3.12.0"          | true
    "4.0.0"       | "^3.12.0"          | false
    "0.2.5"       | "^0.2.3"           | true
    "0.3.0"       | "^0.2.3"           | false
    "0.0.3"       | "^0.0.3"           | true
    "0.0.4"       | "^0.0.3"           | false
    "1.2.9"       | "~1.2.3"           | true
    "1.3.0"       | "~1.2.3"           | false
    "2.5.0"       | ">=1.0.0 <3.0.0"   | true
  end

  test "Any is satisfied by any release, and by no prerelease" do
    Expect
    scheme.satisfies?(pv("3.12.0"), Requirement::Any.new)
    !scheme.satisfies?(pv("3.12.0-rc.1"), Requirement::Any.new)
  end

  test "sorts semver-correctly, prereleases below their release" do
    Given "releases and prereleases out of order"
    versions = ["1.0.0", "1.0.0-rc.1", "0.9.0", "1.0.0-beta"].map { |v| pv(v) }

    When "sorting"
    sorted = scheme.sort(versions).map(&:version)

    Then
    sorted == ["0.9.0", "1.0.0-beta", "1.0.0-rc.1", "1.0.0"]
  end

  test "orders numeric prerelease identifiers numerically" do
    Expect "rc.10 sorts above rc.2 (numeric, not lexicographic)"
    scheme.sort([pv("1.0.0-rc.10"), pv("1.0.0-rc.2")]).map(&:version) == ["1.0.0-rc.2", "1.0.0-rc.10"]
  end

  test "rejects a version that is not semver" do
    When "sorting a non-semver string"
    scheme.sort([pv("not-semver")])

    Then
    raises Dev::Deps::SemverScheme::InvalidVersionError
  end

  test "rejects a requirement version that is not semver" do
    When "evaluating a requirement over four segments"
    scheme.satisfies?(pv("1.0.0"), Requirement.parse(">= 1.2.3.4"))

    Then
    raises Dev::Deps::VersionScheme::InvalidRequirementError
  end
end
