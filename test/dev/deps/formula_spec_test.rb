# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/formula_spec"

transform!(RSpock::AST::Transformation)
class Dev::Deps::FormulaSpecTest < Minitest::Test
  FormulaSpec = Dev::Deps::FormulaSpec
  Requirement = Dev::Deps::Requirement

  test "#{spec.inspect} is #{name} with suffix #{suffix.inspect} asking #{requirement.inspect}" do
    When "parsing a formula spec"
    parsed = FormulaSpec.parse(spec)

    Then "the suffix is read as the version line it names"
    parsed.name == name
    parsed.suffix == suffix
    parsed.versioned? == !suffix.nil?
    parsed.requirement.to_s == requirement
    parsed.to_s == spec

    Where
    spec            | name      | suffix | requirement
    "llvm"          | "llvm"    | nil    | ""
    "llvm@18"       | "llvm"    | "18"   | "~> 18.0"
    "python@3.12"   | "python"  | "3.12" | "~> 3.12.0"
    "openssl@1.1"   | "openssl" | "1.1"  | "~> 1.1.0"
  end

  test "a bare spec asks for Any" do
    Expect
    FormulaSpec.parse("cmake").requirement == Requirement::Any.new
  end

  test "#{spec.inspect} is not a formula spec" do
    When
    FormulaSpec.parse(spec)

    Then
    raises FormulaSpec::InvalidSpecError

    Where
    spec
    ""
    "llvm@"
    "llvm@latest"
    "llvm@18@19"
    "llvm 18"
  end

  test "specs compare by value" do
    Expect
    FormulaSpec.parse("llvm@18") == FormulaSpec.new(name: "llvm", suffix: "18")
    FormulaSpec.parse("llvm@18") != FormulaSpec.parse("llvm@19")
  end
end
