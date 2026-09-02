# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/rock_scheme"

transform!(RSpock::AST::Transformation)
class Dev::Deps::RockSchemeTest < Minitest::Test
  def scheme
    Dev::Deps::RockScheme.new
  end

  test "#{version} against #{requirement.inspect} is #{expected}" do
    When "evaluating the requirement under luarocks semantics"
    result = scheme.satisfies?(version, { "constraint" => requirement })

    Then
    result == expected

    Where
    version   | requirement     | expected
    "3.4-1"   | ">= 3.0"        | true
    "2.1-2"   | ">= 3.0"        | false
    "3.4-1"   | "3.4-1"         | true
    "3.4-2"   | "3.4-1"         | false
    "3.4-1"   | "== 3.4-1"      | true
    "1.0.5-1" | "~> 1.0"        | true
    "2.0-1"   | "~> 1.0"        | false
    "1.0.6-1" | "~> 1.0.5"      | true
    "1.1-1"   | "~> 1.0.5"      | false
    "3.5-1"   | ">= 3.0, < 4.0" | true
    "4.0-1"   | ">= 3.0, < 4.0" | false
  end

  test "an empty constraint is satisfied by anything" do
    Expect
    scheme.satisfies?("3.4-1", {})
  end

  test "a revision counts as a release above the unrevised version" do
    Expect "3.4-1 is a release of 3.4, not a prerelease below it"
    scheme.sort(["3.4-1", "3.4"]) == ["3.4", "3.4-1"]
  end

  test "sorts by dotted segments then revision" do
    Given "rock versions with revisions out of order"
    versions = ["3.4-2", "3.3-5", "3.4-1", "3.10-1"]

    When "sorting"
    sorted = scheme.sort(versions)

    Then "numeric segment ordering, 3.10 above 3.4"
    sorted == ["3.3-5", "3.4-1", "3.4-2", "3.10-1"]
  end

  test "rejects a version it cannot parse" do
    When "sorting a non-rock string"
    scheme.sort(["one.two"])

    Then
    raises Dev::Deps::RockScheme::InvalidVersionError
  end

  test "rejects a constraint it cannot parse" do
    When "evaluating a malformed constraint"
    scheme.satisfies?("3.4-1", { "constraint" => "~~> 3.0" })

    Then
    raises Dev::Deps::RockScheme::InvalidConstraintError
  end
end
