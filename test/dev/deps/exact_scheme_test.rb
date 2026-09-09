# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/package_version"
require "dev/deps/exact_scheme"

transform!(RSpock::AST::Transformation)
class Dev::Deps::ExactSchemeTest < Minitest::Test
  def scheme
    Dev::Deps::ExactScheme.new(key: "tag")
  end

  def pv(version)
    Dev::Deps::PackageVersion.new(version: version)
  end

  test "#{version} against tag #{tag.inspect} is #{expected}" do
    When "evaluating exact-coordinate semantics"
    result = scheme.satisfies?(pv(version), tag.nil? ? {} : { "tag" => tag })

    Then
    result == expected

    Where
    version | tag | expected
    "5.6.1-css-83" | "5.6.1-css-83" | true
    "5.6.1-css-83" | "5.6.1-css-84" | false
    "5.6.1-css-83" | nil            | true
  end

  test "sort preserves order — exact coordinates carry none to impose" do
    When "sorting"
    sorted = scheme.sort(["b", "a", "c"])

    Then
    sorted == ["b", "a", "c"]
  end
end
