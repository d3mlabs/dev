# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/pep440_scheme"

transform!(RSpock::AST::Transformation)
class Dev::Deps::Pep440SchemeTest < Minitest::Test
  def scheme
    Dev::Deps::Pep440Scheme.new
  end

  test "#{version} against #{requirement.inspect} is #{expected}" do
    When "evaluating the specifier under PEP 440 semantics"
    result = scheme.satisfies?(version, { "version" => requirement })

    Then
    result == expected

    Where
    version    | requirement    | expected
    "2.0.5"    | ">=2.0"        | true
    "1.9"      | ">=2.0"        | false
    "2.0.5"    | "2.0.5"        | true
    "2.0.6"    | "2.0.5"        | false
    "2.0.5"    | "==2.0.5"      | true
    "2.0.5"    | "==2.0.*"      | true
    "2.1.0"    | "==2.0.*"      | false
    "2.0.5"    | "~=2.0.3"      | true
    "2.1.0"    | "~=2.0.3"      | false
    "3.5"      | "~=3.0"        | true
    "4.0"      | "~=3.0"        | false
    "2.0.0rc1" | ">=2.0.0"      | false
    "2.0.0"    | "!=2.0.0"      | false
    "2.0.1"    | "!=2.0.0"      | true
    "2.5"      | ">=2.0,<3.0"   | true
    "3.0"      | ">=2.0,<3.0"   | false
    "2.0"      | "==2.0.0"      | true
  end

  test "an empty constraint is satisfied by anything" do
    Expect
    scheme.satisfies?("2.0.5", {})
  end

  test "sorts by PEP 440 ordering: dev < pre < release < post" do
    Given "a full spread of release phases"
    versions = ["2.0.0", "2.0.0rc1", "2.0.0a1", "1.9.9", "2.0.0.post1", "2.0.0.dev1"]

    When "sorting"
    sorted = scheme.sort(versions)

    Then
    sorted == ["1.9.9", "2.0.0.dev1", "2.0.0a1", "2.0.0rc1", "2.0.0", "2.0.0.post1"]
  end

  test "an epoch outranks any epoch-less version" do
    Expect
    scheme.sort(["1!1.0", "99.0"]) == ["99.0", "1!1.0"]
  end

  test "rejects a version it cannot parse" do
    When "sorting a non-PEP-440 string"
    scheme.sort(["totally/wrong"])

    Then
    raises Dev::Deps::Pep440Scheme::InvalidVersionError
  end

  test "rejects a specifier it cannot parse" do
    When "evaluating a malformed specifier"
    scheme.satisfies?("2.0", { "version" => "=>2.0" })

    Then
    raises Dev::Deps::Pep440Scheme::InvalidConstraintError
  end
end
