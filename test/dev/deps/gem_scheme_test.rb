# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/package_version"
require "dev/deps/requirement"
require "dev/deps/gem_scheme"

transform!(RSpock::AST::Transformation)
class Dev::Deps::GemSchemeTest < Minitest::Test
  Requirement = Dev::Deps::Requirement

  def scheme
    Dev::Deps::GemScheme.new
  end

  def pv(version)
    Dev::Deps::PackageVersion.new(version: version)
  end

  test "#{version} against #{expression.inspect} is #{expected}" do
    When "evaluating the requirement under rubygems semantics"
    result = scheme.satisfies?(pv(version), Requirement.parse(expression))

    Then
    result == expected

    Where
    version  | expression        | expected
    "1.17.4" | "^1.17"           | true
    "2.0.0"  | "^1.17"           | false
    "1.17.4" | ">= 1.0, < 2.0"   | true
    "2.1.0"  | ">= 1.0, < 2.0"   | false
    "1.17.4" | "1.17.4"          | true
    "1.17.5" | "1.17.4"          | false
    "1.0.0"  | ">= 1.0.0.beta"   | true
    "1.0.5"  | "^1.0 >=1.0.5"    | true
    "1.0.4"  | "^1.0 >=1.0.5"    | false
  end

  test "Any is satisfied by anything" do
    Expect
    scheme.satisfies?(pv("1.17.4"), Requirement::Any.new)
  end

  test "render translates #{expression.inspect} comparator for comparator into a Gem::Requirement" do
    When "rendering for bundler"
    rendered = scheme.render(Requirement.parse(expression))

    Then "the tool's own type carries the comparators the range means"
    rendered == Gem::Requirement.new(gem_terms)

    Where
    expression       | gem_terms
    "^1.17"          | [">= 1.17.0", "< 2.0.0"]
    "~1.17"          | [">= 1.17.0", "< 1.18.0"]
    "4.0.1"          | ["= 4.0.1"]
    ">=1.0 <2.0"     | [">= 1.0", "< 2.0"]
    "^1.0 >=1.0.5"   | [">= 1.0.0", "< 2.0.0", ">= 1.0.5"]
  end

  test "render of Any is rubygems' default requirement" do
    Expect
    scheme.render(Requirement::Any.new) == Gem::Requirement.default
  end

  test "gem supports every form of the language" do
    Expect
    scheme.supports?(Requirement::Any.new)
    scheme.supports?(Requirement.parse("= 1"))
    scheme.supports?(Requirement.parse("^1"))
    scheme.supports?(Requirement.parse(">= 1, < 2"))
  end

  test "sorts by rubygems version ordering, prereleases below their release" do
    Given "versions out of order, one a prerelease"
    versions = ["1.0.0", "1.0.0.beta", "0.9.0", "1.0.1"].map { |v| pv(v) }

    When "sorting"
    sorted = scheme.sort(versions).map(&:version)

    Then
    sorted == ["0.9.0", "1.0.0.beta", "1.0.0", "1.0.1"]
  end

  test "rejects a version string rubygems cannot parse" do
    When "sorting garbage"
    scheme.sort([pv("not a version")])

    Then
    raises Dev::Deps::GemScheme::InvalidVersionError
  end

  test "rejects a requirement version rubygems cannot read" do
    When "evaluating a requirement over a brew revision"
    scheme.satisfies?(pv("1.0.0"), Requirement.parse(">= 3.11.4_1"))

    Then
    raises Dev::Deps::GemScheme::InvalidRequirementError
  end
end
