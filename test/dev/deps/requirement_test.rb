# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/requirement"

transform!(RSpock::AST::Transformation)
class Dev::Deps::RequirementTest < Minitest::Test
  Requirement = Dev::Deps::Requirement

  test "#{expression.inspect} parses to #{node} and round-trips through to_s" do
    When "parsing"
    parsed = Requirement.parse(expression)

    Then "the canonical node is chosen and its spelling re-parses to itself"
    parsed.instance_of?(node)
    parsed.to_s == canonical
    Requirement.parse(parsed.to_s) == parsed

    Where
    expression            | node                     | canonical
    nil                   | Requirement::Any         | ""
    ""                    | Requirement::Any         | ""
    "   "                 | Requirement::Any         | ""
    "4.0.1"               | Requirement::Exact       | "= 4.0.1"
    "= 4.0.1"             | Requirement::Exact       | "= 4.0.1"
    "=4.0.1"              | Requirement::Exact       | "= 4.0.1"
    "~> 18.0"             | Requirement::Pessimistic | "~> 18.0"
    "~>18"                | Requirement::Pessimistic | "~> 18"
    ">= 2"                | Requirement::Bounds      | ">= 2"
    "> 2"                 | Requirement::Bounds      | "> 2"
    "<= 2"                | Requirement::Bounds      | "<= 2"
    "< 2"                 | Requirement::Bounds      | "< 2"
    "!= 2.1"              | Requirement::Bounds      | "!= 2.1"
    ">= 2, < 3"           | Requirement::Bounds      | ">= 2, < 3"
    "~> 1.0, >= 1.0.5"    | Requirement::Bounds      | "~> 1.0, >= 1.0.5"
    "= 1.0, != 1.0"       | Requirement::Bounds      | "= 1.0, != 1.0"
    "3.11.4_1"            | Requirement::Exact       | "= 3.11.4_1"
    "5.6.1-css-83"        | Requirement::Exact       | "= 5.6.1-css-83"
  end

  test "#{expression.inspect} is not a requirement" do
    When "parsing"
    Requirement.parse(expression)

    Then
    raises Requirement::ParseError

    Where
    expression
    "nope"
    ">>= 1"
    "^1.2.3"
    "~1.2.3"
    ">= "
    "latest"
    "v1.2.3"
  end

  test "~> over a version rubygems cannot bump is refused" do
    When "parsing a pessimistic term over a brew revision"
    Requirement.parse("~> 3.11.4_1")

    Then
    raises Requirement::ParseError
  end

  test "~> #{version} expands to >= #{version}, < #{upper}" do
    When "reading the bounds"
    bounds = Requirement.parse("~> #{version}").bounds

    Then
    bounds == [
      Requirement::Bound.new(operator: ">=", version: version),
      Requirement::Bound.new(operator: "<", version: upper),
    ]

    Where
    version      | upper
    "18.0"       | "19"
    "18"         | "19"
    "1.2.3"      | "1.3"
    "3.12.0"     | "3.13"
    "1.0.0.beta" | "1.1"
  end

  test "terms keep ~> as written while bounds expand it" do
    Given "a conjunction with a pessimistic term"
    parsed = Requirement.parse("~> 1.0, >= 1.0.5")

    Expect "terms is what was written, bounds comparators alone"
    parsed.terms.map(&:to_s) == ["~> 1.0", ">= 1.0.5"]
    parsed.bounds.map(&:to_s) == [">= 1.0", "< 2", ">= 1.0.5"]
  end

  test "comparator terms' bounds are themselves" do
    Given "an exact and a range"
    exact = Requirement.parse("= 4.0.1")
    range = Requirement.parse(">= 2, < 3")

    Expect
    exact.bounds == exact.terms
    range.bounds == range.terms
    exact.bounds == [Requirement::Bound.new(operator: "=", version: "4.0.1")]
  end

  test "any? is true for the empty ask alone" do
    Expect
    Requirement.parse(nil).any?
    Requirement::Any.new.any?
    !Requirement.parse("4.0.1").any?
    !Requirement.parse("~> 1").any?
    !Requirement.parse(">= 1").any?
  end

  test "requirements compare by value" do
    Expect
    Requirement.parse("~> 18.0") == Requirement::Pessimistic.new(version: "18.0")
    Requirement.parse("4.0.1") == Requirement::Exact.new(version: "4.0.1")
    Requirement.parse(">= 2, < 3") == Requirement::Bounds.new(terms: [
      Requirement::Bound.new(operator: ">=", version: "2"),
      Requirement::Bound.new(operator: "<", version: "3"),
    ])
    Requirement.parse("~> 18.0") != Requirement.parse("~> 18")
    Requirement.parse("4.0.1") != Requirement.parse(">= 4.0.1")
  end
end
