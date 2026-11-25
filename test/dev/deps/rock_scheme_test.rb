# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/package_version"
require "dev/deps/requirement"
require "dev/deps/rock_scheme"

transform!(RSpock::AST::Transformation)
class Dev::Deps::RockSchemeTest < Minitest::Test
  Requirement = Dev::Deps::Requirement

  def scheme
    Dev::Deps::RockScheme.new
  end

  def pv(version)
    Dev::Deps::PackageVersion.new(version: version)
  end

  test "#{version} against #{expression.inspect} is #{expected}" do
    When "evaluating dev's requirement under luarocks ordering"
    result = scheme.satisfies?(pv(version), Requirement.parse(expression))

    Then
    result == expected

    Where
    version   | expression      | expected
    "3.4-1"   | ">= 3.0"        | true
    "2.1-2"   | ">= 3.0"        | false
    "3.4-1"   | "3.4-1"         | true
    "3.4-2"   | "3.4-1"         | false
    "3.4-1"   | "= 3.4-1"       | true
    "1.0.5-1" | "^1.0"          | true
    "2.0-1"   | "^1.0"          | false
    "1.0.6-1" | "~1.0.5"        | true
    "1.1-1"   | "~1.0.5"        | false
    "3.5-1"   | ">= 3.0, < 4.0" | true
    "4.0-1"   | ">= 3.0, < 4.0" | false
    "3.1-1"   | "> 3.0"         | true
    "2.9-1"   | "> 3.0"         | false
    "2.9-1"   | "<= 3.0"        | true
    "3.1-1"   | "<= 3.0"        | false
  end

  test "Any is satisfied by anything" do
    Expect
    scheme.satisfies?(pv("3.4-1"), Requirement::Any.new)
  end

  test "a revision counts as a release above the unrevised version" do
    Expect "3.4-1 is a release of 3.4, not a prerelease below it"
    scheme.sort([pv("3.4-1"), pv("3.4")]).map(&:version) == ["3.4", "3.4-1"]
  end

  test "sorts by dotted segments then revision" do
    Given "rock versions with revisions out of order"
    versions = ["3.4-2", "3.3-5", "3.4-1", "3.10-1"].map { |v| pv(v) }

    When "sorting"
    sorted = scheme.sort(versions).map(&:version)

    Then "numeric segment ordering, 3.10 above 3.4"
    sorted == ["3.3-5", "3.4-1", "3.4-2", "3.10-1"]
  end

  test "rejects a version it cannot parse" do
    When "sorting a non-rock string"
    scheme.sort([pv("one.two")])

    Then
    raises Dev::Deps::RockScheme::InvalidVersionError
  end

  test "rejects a requirement version it cannot read" do
    When "evaluating a requirement over a version luarocks does not write"
    scheme.satisfies?(pv("3.4-1"), Requirement.parse(">= 3.0rc1"))

    Then
    raises Dev::Deps::VersionScheme::InvalidRequirementError
  end
end
