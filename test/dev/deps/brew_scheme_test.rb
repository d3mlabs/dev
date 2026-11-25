# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/package_version"
require "dev/deps/requirement"
require "dev/deps/brew_scheme"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BrewSchemeTest < Minitest::Test
  Requirement = Dev::Deps::Requirement

  def scheme
    Dev::Deps::BrewScheme.new
  end

  def pv(version, suffix: nil)
    metadata = suffix ? { "version_suffix" => suffix } : {}
    Dev::Deps::PackageVersion.new(version: version, metadata: metadata)
  end

  test "a family suffix's requirement (~18) is evaluated over the members' real versions" do
    Given "the llvm family as brew reports it"
    requirement = Requirement.parse("~18")

    Expect "the @18 member's real version satisfies, the others do not"
    scheme.satisfies?(pv("18.1.8", suffix: "18"), requirement)
    !scheme.satisfies?(pv("19.1.7", suffix: "19"), requirement)
    !scheme.satisfies?(pv("21.1.0"), requirement)
  end

  test "#{version} against #{expression.inspect} is #{expected}" do
    When "evaluating under brew's tolerant ordering"
    result = scheme.satisfies?(pv(version), Requirement.parse(expression))

    Then
    result == expected

    Where
    version       | expression          | expected
    "3.11.4_1"    | "> 3.11.4"          | true
    "3.11.4_1"    | "~3.11.0"           | true
    "3.11.4_1"    | "< 3.11.5"          | true
    "3.11.4"      | "= 3.11.4"          | true
    "3.11.4_1"    | "= 3.11.4"          | false
    "3.11.4_1"    | "= 3.11.4_1"        | true
    "2024-01-15"  | ">= 2024-01-01"     | true
    "2024-01-15"  | "< 2024-02-01"      | true
    "1.0.0-beta"  | ">= 1.0.0"          | false
    "1.0.0"       | ">= 1.0.0-beta"     | true
    "1.21.0"      | ">= 1.2.0"          | true
    "1.0r3"       | "> 1.0r2"           | true
    "1.0r3"       | "> 1.0"             | true
    "1.0p1"       | "> 1.0"             | true
    "1.0.0-alpha" | "< 1.0.0-beta"      | true
  end

  test "sort orders revision, date and prerelease versions brew's way" do
    Given "versions of every shape brew writes, out of order"
    versions = ["3.11.4_1", "3.11.4", "3.11.10", "3.11.4_2", "3.11.5-rc1", "3.11.5"].map { |v| pv(v) }

    When "sorting"
    sorted = scheme.sort(versions).map(&:version)

    Then "a revision sits above its base, a prerelease below its release, and 10 above 4"
    sorted == ["3.11.4", "3.11.4_1", "3.11.4_2", "3.11.5-rc1", "3.11.5", "3.11.10"]
  end

  test "sort orders date and r-revision versions" do
    Given
    dates = ["2024-01-15", "2023-12-31", "2024-02-01"].map { |v| pv(v) }
    revisions = ["1.0r3", "1.0r10", "1.0r2"].map { |v| pv(v) }

    Expect
    scheme.sort(dates).map(&:version) == ["2023-12-31", "2024-01-15", "2024-02-01"]
    scheme.sort(revisions).map(&:version) == ["1.0r2", "1.0r3", "1.0r10"]
  end

  test "Any is satisfied by every version" do
    Expect
    scheme.satisfies?(pv("3.31.4"), Requirement::Any.new)
    scheme.satisfies?(pv("3.11.4_1"), Requirement::Any.new)
  end

  test "brew supports every form of the language" do
    Expect
    scheme.supports?(Requirement::Any.new)
    scheme.supports?(Requirement.parse("= 18.1.8"))
    scheme.supports?(Requirement.parse("~18"))
    scheme.supports?(Requirement.parse(">= 18, < 20"))
  end

  test "a one-version family refuses a range, naming the version it has" do
    Given "a formula with no versioned siblings"
    family = [pv("3.31.4")]

    When "a range is asked of it"
    message = scheme.refusal(name: "cmake", requirement: Requirement.parse("~3.31.0"), versions: family)

    Then "the refusal names the one version and both ways to say it"
    message.include?("cmake: brew has one version of it, 3.31.4")
    message.include?("~3.31.0")
    message.include?('brew "cmake"')
    message.include?('brew "cmake", "3.31.4"')
  end

  test "a one-version family answers Any and its exact version" do
    Given
    family = [pv("3.31.4")]

    Expect "no refusal"
    scheme.refusal(name: "cmake", requirement: Requirement::Any.new, versions: family).nil?
    scheme.refusal(name: "cmake", requirement: Requirement.parse("= 3.31.4"), versions: family).nil?
  end

  test "a family with several versions answers a range" do
    Given
    family = [pv("21.1.0"), pv("19.1.7", suffix: "19"), pv("18.1.8", suffix: "18")]

    Expect
    scheme.refusal(name: "llvm", requirement: Requirement.parse("~18"), versions: family).nil?
  end

  test "a version brew's ordering cannot read is not a candidate" do
    When "evaluating a word as a version"
    scheme.satisfies?(pv("HEAD"), Requirement.parse(">= 1"))

    Then
    raises Dev::Deps::BrewScheme::InvalidVersionError
  end
end
