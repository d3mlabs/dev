# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/package_version"
require "dev/deps/requirement"
require "dev/deps/git_scheme"

transform!(RSpock::AST::Transformation)
class Dev::Deps::GitSchemeTest < Minitest::Test
  Requirement = Dev::Deps::Requirement
  SHA = "abcdef1234567890abcdef1234567890abcdef12"

  def scheme
    Dev::Deps::GitScheme.new
  end

  def pv(version, ref: nil)
    metadata = ref ? { "ref" => ref } : {}
    Dev::Deps::PackageVersion.new(version: version, metadata: metadata)
  end

  test "an exact ref matches the version's ref fact by name, not the SHA" do
    Given "the ask a tag: keyword makes"
    requirement = Requirement::Exact.new(version: "v1.17.0")

    Expect
    scheme.satisfies?(pv(SHA, ref: "v1.17.0"), requirement)
    !scheme.satisfies?(pv(SHA, ref: "v1.16.0"), requirement)
    !scheme.satisfies?(pv(SHA), Requirement::Exact.new(version: SHA))
  end

  test "a branch is an exact ref the same way — heads are enumerated refs too" do
    Given
    requirement = Requirement::Exact.new(version: "main")

    Expect
    scheme.satisfies?(pv(SHA, ref: "main"), requirement)
    !scheme.satisfies?(pv(SHA, ref: "develop"), requirement)
  end

  test "a range reads the refs that are versions, v prefix aside" do
    Given
    requirement = Requirement.parse("^1.17")

    Expect
    scheme.satisfies?(pv(SHA, ref: "v1.17.0"), requirement)
    scheme.satisfies?(pv(SHA, ref: "1.18.2"), requirement)
    !scheme.satisfies?(pv(SHA, ref: "v2.0.0"), requirement)
  end

  test "a ref that is no version is not a candidate for a range" do
    When "ranging over a branch head"
    scheme.satisfies?(pv(SHA, ref: "main"), Requirement.parse(">= 1"))

    Then
    raises Dev::Deps::TagScheme::InvalidVersionError
  end

  test "a version without a ref fact is not a candidate for a range" do
    When
    scheme.satisfies?(pv(SHA), Requirement.parse(">= 1"))

    Then
    raises Dev::Deps::TagScheme::InvalidVersionError
  end

  test "Any is satisfied by any ref" do
    Expect
    scheme.satisfies?(pv(SHA, ref: "v1.0.0"), Requirement::Any.new)
  end

  test "sort orders by the ref's version" do
    When "sorting"
    sorted = scheme.sort([pv("b" * 40, ref: "v1.10.0"), pv("a" * 40, ref: "v1.9.0")]).map { |v| v.metadata["ref"] }

    Then
    sorted == ["v1.9.0", "v1.10.0"]
  end
end
