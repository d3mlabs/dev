# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/package_version"
require "dev/deps/git_scheme"

transform!(RSpock::AST::Transformation)
class Dev::Deps::GitSchemeTest < Minitest::Test
  SHA = "abcdef1234567890abcdef1234567890abcdef12"

  def scheme
    Dev::Deps::GitScheme.new
  end

  def pv(version, ref: nil)
    metadata = ref ? { "ref" => ref } : {}
    Dev::Deps::PackageVersion.new(version: version, metadata: metadata)
  end

  test "a commit constraint matches the version string — the SHA itself" do
    When "evaluating"
    match = scheme.satisfies?(pv(SHA), { "commit" => SHA })
    miss = scheme.satisfies?(pv("0" * 40), { "commit" => SHA })

    Then
    match == true
    miss == false
  end

  test "a tag constraint matches the version's ref fact, not the SHA" do
    When "evaluating a tag against a resolved SHA carrying its ref"
    match = scheme.satisfies?(pv(SHA, ref: "v1.17.0"), { "tag" => "v1.17.0" })
    miss = scheme.satisfies?(pv(SHA, ref: "v1.16.0"), { "tag" => "v1.17.0" })

    Then
    match == true
    miss == false
  end

  test "no ref constraint satisfies anything" do
    When "evaluating an unconstrained declaration"
    result = scheme.satisfies?(pv(SHA), {})

    Then
    result == true
  end

  test "pin extracts commit over tag as the probe" do
    When "pinning"
    commit_pin = scheme.pin({ "commit" => SHA, "tag" => "v1" })
    tag_pin = scheme.pin({ "tag" => "v1.17.0" })
    no_pin = scheme.pin({})

    Then
    commit_pin == SHA
    tag_pin == "v1.17.0"
    no_pin.nil?
  end

  test "sort preserves order — SHAs carry none" do
    When "sorting"
    sorted = scheme.sort(["b", "a"])

    Then
    sorted == ["b", "a"]
  end
end
