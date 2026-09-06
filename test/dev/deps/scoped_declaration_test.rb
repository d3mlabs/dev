# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/declaration"
require "dev/deps/scope"
require "dev/deps/scoped_declaration"

transform!(RSpock::AST::Transformation)
class Dev::Deps::ScopedDeclarationTest < Minitest::Test
  def atom(name: "boost", integration: :cmake, constraint: {})
    Dev::Deps::Declaration.new(name:, integration:, constraint:)
  end

  test "marries a declaration to the context it resolves under" do
    Given "an atom and an explicit scope"
    scope = Dev::Deps::Scope.new(group: :build, host: :darwin, env: "ci")
    scoped = Dev::Deps::ScopedDeclaration.new(declaration: atom, scope: scope, platform: "LinuxServer")

    Expect "both halves are reachable and distinct"
    scoped.declaration == atom
    scoped.scope == scope
    scoped.platform == "LinuxServer"
  end

  test "delegates the atom's facts for call-site ergonomics" do
    Given "a scoped declaration"
    scoped = Dev::Deps::ScopedDeclaration.new(
      declaration: atom(name: "SML", integration: :ficsit, constraint: { "version" => "^3.6" }),
    )

    Expect "name/integration/constraint read through to the atom"
    scoped.name == "SML"
    scoped.integration == :ficsit
    scoped.constraint == { "version" => "^3.6" }
  end

  test "defaults to the default scope, no platform, no hook" do
    Given "a scoped declaration with only an atom"
    scoped = Dev::Deps::ScopedDeclaration.new(declaration: atom)

    Expect
    scoped.scope == Dev::Deps::Scope.new
    scoped.platform.nil?
    scoped.post_install.nil?
  end

  test "is value-equal across independently built compositions" do
    Given "two scoped declarations from the same parts"
    a = Dev::Deps::ScopedDeclaration.new(declaration: atom, scope: Dev::Deps::Scope.new(group: :test))
    b = Dev::Deps::ScopedDeclaration.new(declaration: atom, scope: Dev::Deps::Scope.new(group: :test))

    Expect
    a == b
    { a => 1 }.key?(b)
  end

  test "scope participates in equality — same ask, different context, different value" do
    Given "one atom under two scopes"
    a = Dev::Deps::ScopedDeclaration.new(declaration: atom, scope: Dev::Deps::Scope.new(group: :app))
    b = Dev::Deps::ScopedDeclaration.new(declaration: atom, scope: Dev::Deps::Scope.new(group: :test))

    Expect
    a != b
  end

  test "is not a Declaration — composition keeps context off the facts side" do
    Given "a scoped declaration"
    scoped = Dev::Deps::ScopedDeclaration.new(declaration: atom)

    Expect "it never passes an is_a?(Declaration) gate"
    !scoped.is_a?(Dev::Deps::Declaration)
  end
end
