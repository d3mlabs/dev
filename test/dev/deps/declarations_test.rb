# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/declaration"
require "dev/deps/declarations"

transform!(RSpock::AST::Transformation)
class Dev::Deps::DeclarationsTest < Minitest::Test
  def atom(name)
    Dev::Deps::Declaration.new(name: name, integration: :ficsit, constraint: { "version" => "^1.0" })
  end

  test "Resolved carries the declared dependency list" do
    Given "a resolved claim over two declarations"
    resolved = Dev::Deps::Declarations::Resolved.new([atom("SML"), atom("AreaActions")])

    Expect
    resolved.declarations == [atom("SML"), atom("AreaActions")]
  end

  test "Resolved([]) is an affirmative claim of requiring nothing" do
    Given "a resolved claim with no declarations"
    resolved = Dev::Deps::Declarations::Resolved.new([])

    Expect "the list is present and empty — distinct from ToolOwned"
    resolved.declarations == []
    !resolved.is_a?(Dev::Deps::Declarations::ToolOwned)
  end

  test "Resolved is value-equal and hash-stable" do
    Given "two claims built independently from the same declarations"
    a = Dev::Deps::Declarations::Resolved.new([atom("SML")])
    b = Dev::Deps::Declarations::Resolved.new([atom("SML")])

    Expect
    a == b
    { a => 1 }.key?(b)
  end

  test "Resolved claims over different declarations are not equal" do
    Given
    a = Dev::Deps::Declarations::Resolved.new([atom("SML")])
    b = Dev::Deps::Declarations::Resolved.new([atom("AreaActions")])

    Expect
    a != b
  end

  test "Resolved freezes its list and shrugs off caller mutation" do
    Given "a claim built from a mutable array"
    atoms = [atom("SML")]
    resolved = Dev::Deps::Declarations::Resolved.new(atoms)

    When "the caller mutates its own array afterwards"
    atoms << atom("AreaActions")

    Then
    resolved.declarations.frozen?
    resolved.declarations == [atom("SML")]
  end

  test "ToolOwned instances are value-equal and hash-stable" do
    Given "two independently built tool-owned claims"
    a = Dev::Deps::Declarations::ToolOwned.new
    b = Dev::Deps::Declarations::ToolOwned.new

    Expect
    a == b
    { a => 1 }.key?(b)
  end

  test "ToolOwned never equals Resolved, even an empty one" do
    Given
    tool_owned = Dev::Deps::Declarations::ToolOwned.new
    empty = Dev::Deps::Declarations::Resolved.new([])

    Expect
    tool_owned != empty
    empty != tool_owned
  end

  test "variants discriminate by class in a case expression" do
    Given "one claim of each variant"
    claims = [Dev::Deps::Declarations::Resolved.new([atom("SML")]), Dev::Deps::Declarations::ToolOwned.new]

    When "casing on the variant"
    kinds = claims.map do |claim|
      case claim
      when Dev::Deps::Declarations::Resolved then :resolved
      when Dev::Deps::Declarations::ToolOwned then :tool_owned
      end
    end

    Then
    kinds == [:resolved, :tool_owned]
  end
end
