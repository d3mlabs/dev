# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/semver_scheme"

transform!(RSpock::AST::Transformation)
class Dev::Deps::SemverSchemeTest < Minitest::Test
  def scheme
    Dev::Deps::SemverScheme.new
  end

  test "#{version} against #{requirement.inspect} is #{expected}" do
    When "evaluating the requirement under semver range semantics"
    result = scheme.satisfies?(version, { "version" => requirement })

    Then
    result == expected

    Where
    version       | requirement        | expected
    "3.12.0"      | "^3.12.0"          | true
    "3.13.2"      | "^3.12.0"          | true
    "4.0.0"       | "^3.12.0"          | false
    "3.11.9"      | "^3.12.0"          | false
    "0.2.5"       | "^0.2.3"           | true
    "0.3.0"       | "^0.2.3"           | false
    "0.0.3"       | "^0.0.3"           | true
    "0.0.4"       | "^0.0.3"           | false
    "1.2.9"       | "~1.2.3"           | true
    "1.3.0"       | "~1.2.3"           | false
    "2.5.0"       | ">=1.0.0 <3.0.0"   | true
    "3.0.0"       | ">=1.0.0 <3.0.0"   | false
    "1.0.0"       | "1.0.0"            | true
    "1.0.1"       | "1.0.0"            | false
    "1.0.0"       | "=1.0.0"           | true
    "1.0.0-rc.1"  | ">=1.0.0"          | false
    "1.0.0"       | ">1.0.0-rc.1"      | true
    "1.0.0"       | "<=1.0.0"          | true
    "1.0.1"       | "<=1.0.0"          | false
  end

  test "an empty constraint is satisfied by anything" do
    Expect
    scheme.satisfies?("3.12.0", {})
  end

  test "sorts semver-correctly, prereleases below their release" do
    Given "releases and prereleases out of order"
    versions = ["1.0.0", "1.0.0-rc.1", "0.9.0", "1.0.0-beta"]

    When "sorting"
    sorted = scheme.sort(versions)

    Then
    sorted == ["0.9.0", "1.0.0-beta", "1.0.0-rc.1", "1.0.0"]
  end

  test "orders numeric prerelease identifiers numerically" do
    Expect "rc.10 sorts above rc.2 (numeric, not lexicographic)"
    scheme.sort(["1.0.0-rc.10", "1.0.0-rc.2"]) == ["1.0.0-rc.2", "1.0.0-rc.10"]
  end

  test "rejects a version that is not semver" do
    When "sorting a non-semver string"
    scheme.sort(["not-semver"])

    Then
    raises Dev::Deps::SemverScheme::InvalidVersionError
  end

  test "rejects a constraint it cannot parse" do
    When "evaluating an unparseable range"
    scheme.satisfies?("1.0.0", { "version" => "^^nope" })

    Then
    raises Dev::Deps::SemverScheme::InvalidConstraintError
  end
end
