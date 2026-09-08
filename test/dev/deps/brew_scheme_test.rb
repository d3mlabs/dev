# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/package_version"
require "dev/deps/brew_scheme"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BrewSchemeTest < Minitest::Test
  def scheme
    Dev::Deps::BrewScheme.new
  end

  def pv(version, suffix: nil)
    metadata = suffix ? { "version_suffix" => suffix } : {}
    Dev::Deps::PackageVersion.new(version: version, metadata: metadata)
  end

  test "the version constraint is a formula suffix matched against the suffix fact" do
    When "evaluating suffixed and unsuffixed candidates"
    match = scheme.satisfies?(pv("18.1.8", suffix: "18"), { "version" => "18" })
    miss = scheme.satisfies?(pv("19.1.0", suffix: "19"), { "version" => "18" })
    unsuffixed_miss = scheme.satisfies?(pv("20.0.1"), { "version" => "18" })

    Then "the reported stable version is brew's record, never the coordinate"
    match == true
    miss == false
    unsuffixed_miss == false
  end

  test "no suffix constraint satisfies anything" do
    When "evaluating an unconstrained declaration"
    result = scheme.satisfies?(pv("3.31.4"), {})

    Then
    result == true
  end

  test "sort preserves order — one current version per formula spec" do
    When "sorting"
    sorted = scheme.sort(["b", "a"])

    Then
    sorted == ["b", "a"]
  end
end
