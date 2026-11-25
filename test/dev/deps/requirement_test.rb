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
    expression            | node                | canonical
    nil                   | Requirement::Any    | ""
    ""                    | Requirement::Any    | ""
    "   "                 | Requirement::Any    | ""
    "4.0.1"               | Requirement::Exact  | "=4.0.1"
    "= 4.0.1"             | Requirement::Exact  | "=4.0.1"
    "=4.0.1"              | Requirement::Exact  | "=4.0.1"
    "^1"                  | Requirement::Caret  | "^1"
    "^ 1.2"               | Requirement::Caret  | "^1.2"
    "^1.2.3-beta.1"       | Requirement::Caret  | "^1.2.3-beta.1"
    "~1.2.3"              | Requirement::Tilde  | "~1.2.3"
    "~ 18"                | Requirement::Tilde  | "~18"
    ">=2"                 | Requirement::Bounds | ">=2"
    "> 2"                 | Requirement::Bounds | ">2"
    "<= 2"                | Requirement::Bounds | "<=2"
    "< 2"                 | Requirement::Bounds | "<2"
    ">=2 <3"              | Requirement::Bounds | ">=2 <3"
    ">= 2, < 3"           | Requirement::Bounds | ">=2 <3"
    ">=1.0.0,<2.0.0"      | Requirement::Bounds | ">=1.0.0 <2.0.0"
    "^1.0 >=1.0.5"        | Requirement::Bounds | "^1.0 >=1.0.5"
    "=1.0 <1.0"           | Requirement::Bounds | "=1.0 <1.0"
    "3.11.4_1"            | Requirement::Exact  | "=3.11.4_1"
    "5.6.1-css-83"        | Requirement::Exact  | "=5.6.1-css-83"
    ">= 1.0.0-0"          | Requirement::Bounds | ">=1.0.0-0"
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
    "!= 2.1"
    ">= "
    "latest"
    "v1.2.3"
    "1.2.3 - 2.3.4"
    ">=1.0.0 || <0.5.0"
  end

  test "~> #{version} is refused naming #{replacement} as the semver spelling" do
    When "parsing bundler's pessimistic operator"
    Requirement.parse("~> #{version}")

    Then "the refusal maps the operator to the semver range it means"
    e = raises Requirement::PessimisticOperatorError
    e.message.start_with?("~> #{version} → #{replacement}")
    e.message.include?("bundler's operator")

    Where
    version      | replacement
    "1"          | "^1"
    "0"          | "^0"
    "1.2"        | "^1.2"
    "18.0"       | "^18.0"
    "0.2"        | ">=0.2 <1"
    "1.2.3"      | "~1.2.3"
    "0.2.3"      | "~0.2.3"
    "1.2.3.4"    | ">=1.2.3.4 <1.2.4"
    "1.0.0.beta" | ">=1.0.0.beta <1.1"
  end

  test "~> beside other terms is refused too, and spacing does not matter" do
    When "parsing a conjunction with a pessimistic term"
    Requirement.parse(">= 1.0.5, ~>1.0")

    Then
    e = raises Requirement::PessimisticOperatorError
    e.message.start_with?("~> 1.0 → ^1.0")
  end

  test "~> over a version rubygems cannot bump is refused with no spelling" do
    When "parsing a pessimistic term over a brew revision"
    Requirement.parse("~> 3.11.4_1")

    Then
    e = raises Requirement::PessimisticOperatorError
    e.message.include?("has no semver spelling")
  end

  test "#{operator}#{version} over a version semver cannot bump is refused" do
    When "parsing a shorthand over a non-semver version"
    Requirement.parse("#{operator}#{version}")

    Then
    e = raises Requirement::ParseError
    e.message.include?("needs a semver version")

    Where
    operator | version
    "^"      | "3.11.4_1"
    "~"      | "1.2.3.4"
    "^"      | "1.0r3"
    "~"      | "2.0.x"
  end

  test "#{expression} expands to #{lower} and #{upper}" do
    When "reading the bounds"
    bounds = Requirement.parse(expression).bounds

    Then
    bounds == [
      Requirement::Bound.new(operator: ">=", version: lower),
      Requirement::Bound.new(operator: "<", version: upper),
    ]

    Where
    expression      | lower          | upper
    "^1"            | "1.0.0"        | "2.0.0"
    "^1.2"          | "1.2.0"        | "2.0.0"
    "^1.2.3"        | "1.2.3"        | "2.0.0"
    "^0.2.3"        | "0.2.3"        | "0.3.0"
    "^0.0.3"        | "0.0.3"        | "0.0.4"
    "^0.0"          | "0.0.0"        | "0.1.0"
    "^0"            | "0.0.0"        | "1.0.0"
    "^0.0.0"        | "0.0.0"        | "0.0.1"
    "^1.0.0-beta.1" | "1.0.0-beta.1" | "2.0.0"
    "^1.2.3+build"  | "1.2.3"        | "2.0.0"
    "~1.2.3"        | "1.2.3"        | "1.3.0"
    "~1.2"          | "1.2.0"        | "1.3.0"
    "~1"            | "1.0.0"        | "2.0.0"
    "~0.2.3"        | "0.2.3"        | "0.3.0"
    "~0"            | "0.0.0"        | "1.0.0"
    "~18"           | "18.0.0"       | "19.0.0"
    "~3.12"         | "3.12.0"       | "3.13.0"
    "~1.2.3-rc.1"   | "1.2.3-rc.1"   | "1.3.0"
  end

  test "terms keep a shorthand as written while bounds expand it" do
    Given "conjunctions with a caret term and with a tilde term"
    caret = Requirement.parse("^1.0 >=1.0.5")
    tilde = Requirement.parse("~1.2 >=1.2.5")

    Expect "terms is what was written, bounds comparators alone"
    caret.terms.map(&:to_s) == ["^1.0", ">=1.0.5"]
    caret.bounds.map(&:to_s) == [">=1.0.0", "<2.0.0", ">=1.0.5"]
    tilde.terms.map(&:to_s) == ["~1.2", ">=1.2.5"]
    tilde.bounds.map(&:to_s) == [">=1.2.0", "<1.3.0", ">=1.2.5"]
  end

  test "comparator terms' bounds are themselves" do
    Given "an exact and a range"
    exact = Requirement.parse("=4.0.1")
    range = Requirement.parse(">=2 <3")

    Expect
    exact.bounds == exact.terms
    range.bounds == range.terms
    exact.bounds == [Requirement::Bound.new(operator: "=", version: "4.0.1")]
  end

  test "a comparator keeps a prerelease floor so the ask opts into prereleases" do
    Expect "node-semver's `>=1.0.0-0`: the lowest prerelease of 1.0.0 is the floor"
    Requirement.parse(">=1.0.0-0").bounds == [Requirement::Bound.new(operator: ">=", version: "1.0.0-0")]
  end

  test "any? is true for the empty ask alone" do
    Expect
    Requirement.parse(nil).any?
    Requirement::Any.new.any?
    !Requirement.parse("4.0.1").any?
    !Requirement.parse("^1").any?
    !Requirement.parse(">=1").any?
  end

  test "requirements compare by value" do
    Expect
    Requirement.parse("^18.0") == Requirement::Caret.new(version: "18.0")
    Requirement.parse("~18.0") == Requirement::Tilde.new(version: "18.0")
    Requirement.parse("^18") != Requirement::Tilde.new(version: "18")
    Requirement.parse("4.0.1") == Requirement::Exact.new(version: "4.0.1")
    Requirement.parse(">=2 <3") == Requirement::Bounds.new(terms: [
      Requirement::Bound.new(operator: ">=", version: "2"),
      Requirement::Bound.new(operator: "<", version: "3"),
    ])
    Requirement.parse("^18.0") != Requirement.parse("^18")
    Requirement.parse("4.0.1") != Requirement.parse(">=4.0.1")
  end

  test "a shorthand node built directly over a non-semver version is refused" do
    When
    Requirement::Tilde.new(version: "3.11.4_1")

    Then
    raises Requirement::ParseError
  end
end
