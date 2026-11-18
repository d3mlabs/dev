# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/semver_range"

transform!(RSpock::AST::Transformation)
class Dev::Deps::SemverRangeTest < Minitest::Test
  Requirement = Dev::Deps::Requirement

  def parser
    Dev::Deps::SemverRange.new
  end

  test "#{expression.inspect} translates to #{translated.inspect}" do
    When "translating a node-style range into dev's language"
    requirement = parser.parse(expression)

    Then
    requirement.to_s == translated

    Where
    expression         | translated
    "^3.12.0"          | ">= 3.12.0, < 4.0.0"
    "^0.2.3"           | ">= 0.2.3, < 0.3.0"
    "^0.0.3"           | ">= 0.0.3, < 0.0.4"
    "^3"               | ">= 3.0.0, < 4.0.0"
    "~1.2.3"           | ">= 1.2.3, < 1.3.0"
    ">=1.0.0 <2.0.0"   | ">= 1.0.0, < 2.0.0"
    ">=1.0.0, <2.0.0"  | ">= 1.0.0, < 2.0.0"
    ">=1.2"            | ">= 1.2.0"
    ">1.0.0"           | "> 1.0.0"
    "<=2.0.0"          | "<= 2.0.0"
    "=1.2.3"           | "= 1.2.3"
    "^1.0.0-beta.1"    | ">= 1.0.0-beta.1, < 2.0.0"
  end

  test "a bare version is an Exact" do
    When
    requirement = parser.parse("1.2.3")

    Then
    requirement == Requirement::Exact.new(version: "1.2.3")
  end

  test "#{expression.inspect} is not a semver range" do
    When
    parser.parse(expression)

    Then
    raises Dev::Deps::SemverRange::ParseError

    Where
    expression
    ""
    "latest"
    "~> 1.0"
    "^x.1.0"
    ">=1.0.0 ||  <0.5.0"
  end
end
