# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/declaration"

transform!(RSpock::AST::Transformation)
class Dev::Deps::DeclarationTest < Minitest::Test
  test "states a package under a constraint in dev's shape" do
    Given "a declaration with an explicit constraint hash"
    decl = Dev::Deps::Declaration.new(
      name: "SML", integration: :ficsit, constraint: { "version" => "^3.6.0" },
    )

    Expect "the atom's three facts are readable"
    decl.name == "SML"
    decl.integration == :ficsit
    decl.constraint == { "version" => "^3.6.0" }
  end

  test "unconstrained is the empty hash, a present empty form" do
    Given "a declaration without a constraint"
    decl = Dev::Deps::Declaration.new(name: "boost", integration: :cmake)

    Expect "the constraint is {} — never nil"
    decl.constraint == {}
  end

  test "is value-equal and hash-stable" do
    Given "two declarations built independently from the same facts"
    a = Dev::Deps::Declaration.new(name: "ffi", integration: :bundler, constraint: { "version" => "~> 1.17" })
    b = Dev::Deps::Declaration.new(name: "ffi", integration: :bundler, constraint: { "version" => "~> 1.17" })

    Expect "they are equal and collapse to one hash key"
    a == b
    { a => 1 }.key?(b)
  end

  test "the same name under different integrations is a different declaration" do
    Given "'ffi' declared against bundler and against pip"
    gem_decl = Dev::Deps::Declaration.new(name: "ffi", integration: :bundler)
    pip_decl = Dev::Deps::Declaration.new(name: "ffi", integration: :pip)

    Expect
    gem_decl != pip_decl
  end

  test "is frozen, constraint included" do
    Given "a declaration"
    decl = Dev::Deps::Declaration.new(name: "boost", integration: :cmake, constraint: { "tag" => "1.0" })

    Expect "the value and its constraint resist mutation"
    decl.frozen?
    decl.constraint.frozen?
  end

  test "carries a source coordinate as an identity field, not a constraint key" do
    Given "a source-based declaration"
    decl = Dev::Deps::Declaration.new(
      name: "fmt", integration: :cmake,
      constraint: { "tag" => "11.0.2" }, source: "https://github.com/fmtlib/fmt",
    )

    Expect "source is a field and the constraint holds only version-shaped keys"
    decl.source == "https://github.com/fmtlib/fmt"
    decl.constraint == { "tag" => "11.0.2" }
  end

  test "source defaults to nil for registry-backed packages" do
    Given "a registry-backed declaration"
    decl = Dev::Deps::Declaration.new(name: "ffi", integration: :bundler)

    Expect
    decl.source.nil?
  end

  test "source participates in equality — same name, different universe, different declaration" do
    Given "one name declared against two source coordinates"
    a = Dev::Deps::Declaration.new(name: "fmt", integration: :cmake, source: "https://github.com/fmtlib/fmt")
    b = Dev::Deps::Declaration.new(name: "fmt", integration: :cmake, source: "https://github.com/fork/fmt")

    Expect
    a != b
    a.hash != b.hash
  end

  test "carries a revision as an address, not a constraint key" do
    Given "a declaration pinning an addressable revision"
    decl = Dev::Deps::Declaration.new(
      name: "opencell", integration: :cmake,
      source: "https://github.com/d3mlabs/opencell",
      revision: "ee3042f8b0279856061f91069a487e4ed6f69475",
    )

    Expect "the revision is a field and the constraint stays empty"
    decl.revision == "ee3042f8b0279856061f91069a487e4ed6f69475"
    decl.constraint == {}
  end

  test "revision defaults to nil — most asks select over a universe" do
    Given "a constraint-shaped declaration"
    decl = Dev::Deps::Declaration.new(name: "googletest", integration: :cmake, constraint: { "tag" => "v1.17.0" })

    Expect
    decl.revision.nil?
  end

  test "revision participates in equality — two addresses are two asks" do
    Given "one name pinned at two revisions"
    a = Dev::Deps::Declaration.new(name: "opencell", integration: :cmake, revision: "a" * 40)
    b = Dev::Deps::Declaration.new(name: "opencell", integration: :cmake, revision: "b" * 40)

    Expect
    a != b
    a.hash != b.hash
  end

  test "a revision alongside version constraints is a contradiction, rejected loudly" do
    When "declaring both an address and a selection"
    act = lambda do
      Dev::Deps::Declaration.new(
        name: "opencell", integration: :cmake,
        constraint: { "tag" => "v1.0" }, revision: "a" * 40,
      )
    end

    Then "the atom refuses: an address forgoes resolution, a constraint asks for it"
    error = assert_raises(Dev::Deps::Declaration::RevisionWithConstraintError) { act.call }
    error.message.include?("opencell")
  end
end
