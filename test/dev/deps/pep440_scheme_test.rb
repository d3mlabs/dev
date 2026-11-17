# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/package_version"
require "dev/deps/requirement"
require "dev/deps/pep440_scheme"

transform!(RSpock::AST::Transformation)
class Dev::Deps::Pep440SchemeTest < Minitest::Test
  Requirement = Dev::Deps::Requirement

  def scheme
    Dev::Deps::Pep440Scheme.new
  end

  def pv(version)
    Dev::Deps::PackageVersion.new(version: version)
  end

  test "#{version} against #{expression.inspect} is #{expected}" do
    When "evaluating dev's requirement under PEP 440 ordering"
    result = scheme.satisfies?(pv(version), Requirement.parse(expression))

    Then
    result == expected

    Where
    version    | expression     | expected
    "2.0.5"    | ">= 2.0"       | true
    "1.9"      | ">= 2.0"       | false
    "2.0.5"    | "2.0.5"        | true
    "2.0.6"    | "2.0.5"        | false
    "2.0.5"    | "~> 2.0.3"     | true
    "2.1.0"    | "~> 2.0.3"     | false
    "3.5"      | "~> 3.0"       | true
    "4.0"      | "~> 3.0"       | false
    "2.0.0rc1" | ">= 2.0.0"     | false
    "2.0.0"    | "!= 2.0.0"     | false
    "2.0.1"    | "!= 2.0.0"     | true
    "2.5"      | ">= 2.0, < 3.0" | true
    "3.0"      | ">= 2.0, < 3.0" | false
    "2.0"      | "= 2.0.0"      | true
    "2.1"      | "> 2.0"        | true
    "2.0"      | "> 2.0"        | false
    "2.0"      | "<= 2.0"       | true
    "2.1"      | "<= 2.0"       | false
  end

  test "~> reads as PEP 440's compatible release (~=)" do
    Given "the ~= 2.0.3 spread"
    requirement = Requirement.parse("~> 2.0.3")

    Expect
    scheme.satisfies?(pv("2.0.3"), requirement)
    scheme.satisfies?(pv("2.0.99"), requirement)
    !scheme.satisfies?(pv("2.0.2"), requirement)
    !scheme.satisfies?(pv("2.1"), requirement)
  end

  test "Any is satisfied by anything" do
    Expect
    scheme.satisfies?(pv("2.0.5"), Requirement::Any.new)
  end

  test "sorts by PEP 440 ordering: dev < pre < release < post" do
    Given "a full spread of release phases"
    versions = ["2.0.0", "2.0.0rc1", "2.0.0a1", "1.9.9", "2.0.0.post1", "2.0.0.dev1"].map { |v| pv(v) }

    When "sorting"
    sorted = scheme.sort(versions).map(&:version)

    Then
    sorted == ["1.9.9", "2.0.0.dev1", "2.0.0a1", "2.0.0rc1", "2.0.0", "2.0.0.post1"]
  end

  test "an epoch outranks any epoch-less version" do
    Expect
    scheme.sort([pv("1!1.0"), pv("99.0")]).map(&:version) == ["99.0", "1!1.0"]
  end

  test "rejects a version it cannot parse" do
    When "sorting a non-PEP-440 string"
    scheme.sort([pv("totally/wrong")])

    Then
    raises Dev::Deps::Pep440Scheme::InvalidVersionError
  end

  test "rejects a requirement version it cannot read" do
    When "evaluating a requirement over a version PEP 440 does not write"
    scheme.satisfies?(pv("2.0"), Requirement.parse(">= 2.0.x"))

    Then
    raises Dev::Deps::VersionScheme::InvalidRequirementError
  end
end
