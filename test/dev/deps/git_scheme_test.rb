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

  test "a tag constraint matches the version's ref fact, not the SHA" do
    When "evaluating a tag against resolved SHAs carrying their refs"
    match = scheme.satisfies?(pv(SHA, ref: "v1.17.0"), { "tag" => "v1.17.0" })
    miss = scheme.satisfies?(pv(SHA, ref: "v1.16.0"), { "tag" => "v1.17.0" })
    sha_is_not_a_ref = scheme.satisfies?(pv(SHA), { "tag" => SHA })

    Then
    match == true
    miss == false
    sha_is_not_a_ref == false
  end

  test "a branch constraint matches the same way — heads are enumerated refs too" do
    When "evaluating a branch"
    match = scheme.satisfies?(pv(SHA, ref: "main"), { "branch" => "main" })
    miss = scheme.satisfies?(pv(SHA, ref: "develop"), { "branch" => "main" })

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

  test "sort preserves order — SHAs carry none" do
    When "sorting"
    sorted = scheme.sort(["b", "a"])

    Then
    sorted == ["b", "a"]
  end
end
