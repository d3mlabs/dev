# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/gem_scheme"

transform!(RSpock::AST::Transformation)
class Dev::Deps::GemSchemeTest < Minitest::Test
  def scheme
    Dev::Deps::GemScheme.new
  end

  test "#{version} against #{requirement.inspect} is #{expected}" do
    When "evaluating the requirement under rubygems semantics"
    result = scheme.satisfies?(version, { "version" => requirement })

    Then
    result == expected

    Where
    version  | requirement       | expected
    "1.17.4" | "~> 1.17"         | true
    "2.0.0"  | "~> 1.17"         | false
    "1.17.4" | ">= 1.0, < 2.0"   | true
    "2.1.0"  | ">= 1.0, < 2.0"   | false
    "1.17.4" | "1.17.4"          | true
    "1.17.5" | "1.17.4"          | false
    "1.0.0"  | ">= 1.0.0.beta"   | true
  end

  test "an empty constraint is satisfied by anything" do
    Expect "no version requirement means unconstrained"
    scheme.satisfies?("1.17.4", {})
    scheme.satisfies?("1.17.4", { "require" => false })
  end

  test "sorts by rubygems version ordering, prereleases below their release" do
    Given "versions out of order, one a prerelease"
    versions = ["1.0.0", "1.0.0.beta", "0.9.0", "1.0.1"]

    When "sorting"
    sorted = scheme.sort(versions)

    Then
    sorted == ["0.9.0", "1.0.0.beta", "1.0.0", "1.0.1"]
  end

  test "rejects a version string rubygems cannot parse" do
    When "sorting garbage"
    scheme.sort(["not a version"])

    Then
    raises Dev::Deps::GemScheme::InvalidVersionError
  end

  test "rejects a requirement rubygems cannot parse" do
    When "evaluating a malformed requirement"
    scheme.satisfies?("1.0.0", { "version" => ">>>= nope" })

    Then
    raises Dev::Deps::GemScheme::InvalidConstraintError
  end
end
