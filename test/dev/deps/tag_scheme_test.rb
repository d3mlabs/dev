# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/package_version"
require "dev/deps/requirement"
require "dev/deps/tag_scheme"

transform!(RSpock::AST::Transformation)
class Dev::Deps::TagSchemeTest < Minitest::Test
  Requirement = Dev::Deps::Requirement

  def scheme
    Dev::Deps::TagScheme.new
  end

  def pv(tag)
    Dev::Deps::PackageVersion.new(version: tag)
  end

  test "tag #{tag.inspect} against #{expression.inspect} is #{expected}" do
    When "evaluating a range over the tags that are versions"
    result = scheme.satisfies?(pv(tag), Requirement.parse(expression))

    Then
    result == expected

    Where
    tag          | expression   | expected
    "v3.11.3"    | ">= 3.11"    | true
    "v3.11.3"    | "~> 3.11.0"  | true
    "3.11.3"     | "~> 3.11.0"  | true
    "v3.12.0"    | "~> 3.11.0"  | false
    "v3.11.3"    | "< 3.11.3"   | false
    "V2"         | ">= 2"       | true
    "v3.11.3"    | "= 3.11.3"   | true
  end

  test "an exact tag matches by name as spelled, whatever its shape" do
    Expect "release tags that are not versions still match exactly; a v prefix is read past"
    scheme.satisfies?(pv("v3.11.3"), Requirement::Exact.new(version: "3.11.3"))
    scheme.satisfies?(pv("3.11.3"), Requirement::Exact.new(version: "v3.11.3"))
    scheme.satisfies?(pv("5.6.1-css-83"), Requirement::Exact.new(version: "5.6.1-css-83"))
    scheme.satisfies?(pv("toolchain-2"), Requirement::Exact.new(version: "toolchain-2"))
    scheme.satisfies?(pv("latest"), Requirement::Exact.new(version: "latest"))
    !scheme.satisfies?(pv("toolchain-3"), Requirement::Exact.new(version: "toolchain-2"))
  end

  test "a tag that is no version is not a candidate for a range" do
    When "ranging over a non-version tag"
    scheme.satisfies?(pv(tag), Requirement.parse(">= 1"))

    Then
    raises Dev::Deps::TagScheme::InvalidVersionError

    Where
    tag      | _
    "latest" | "no digit leads it"
    "v1..2"  | "digit-led but no version"
  end

  test "gh takes every form of the language" do
    Expect
    scheme.supports?(Requirement::Any.new)
    scheme.supports?(Requirement::Exact.new(version: "latest"))
    scheme.supports?(Requirement.parse("~> 3.11"))
  end

  test "sort places tags that are not versions below the version tags, in reported order" do
    When "sorting a universe with a branch head and a label among the version tags"
    sorted = scheme.sort(["v1.2.0", "main", "v1.10.0", "latest"].map { |t| pv(t) }).map(&:version)

    Then "an exact ask for `main` still has something to pick; a range never sees it"
    sorted == ["main", "latest", "v1.2.0", "v1.10.0"]
  end

  test "sort orders version tags, v prefix aside, prereleases below their release" do
    When "sorting"
    sorted = scheme.sort(["v3.11.3", "3.11.10", "v3.11.3-rc1", "v3.9.0"].map { |t| pv(t) }).map(&:version)

    Then
    sorted == ["v3.9.0", "v3.11.3-rc1", "v3.11.3", "3.11.10"]
  end
end
