# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/dependency"

transform!(RSpock::AST::Transformation)
class Dev::Deps::DependencyTest < Minitest::Test
  test "creates a dependency with all required fields" do
    When "all fields specified"
    dep = Dev::Deps::Dependency.new(
      name: "boost",
      integration: :cmake,
      group: :app,
      version: "1.90.0",
      hash: "SHA256=deadbeef",
      metadata: { url: "https://example.com/boost.tar.gz" },
    )

    Then
    dep.name == "boost"
    dep.integration == :cmake
    dep.group == :app
    dep.version == "1.90.0"
    dep.hash == "SHA256=deadbeef"
    dep.metadata == { url: "https://example.com/boost.tar.gz" }
    dep.dependencies == []
  end

  test "dependency is frozen (immutable)" do
    Given "a dependency"
    dep = Dev::Deps::Dependency.new(
      name: "boost",
      integration: :cmake,
      group: :app,
      version: "1.90.0",
      hash: "SHA256=deadbeef",
      metadata: {},
    )

    Expect
    dep.frozen?
  end

  test "two dependencies with same fields are equal" do
    Given "identical attributes"
    attrs = { name: "boost", integration: :cmake, group: :app, version: "1.90.0", hash: "SHA256=deadbeef", metadata: {} }

    When
    dep_a = Dev::Deps::Dependency.new(**attrs)
    dep_b = Dev::Deps::Dependency.new(**attrs)

    Then
    dep_a == dep_b
    dep_a.eql?(dep_b)
    dep_a.hash == dep_b.hash
  end

  test "two dependencies with different fields are not equal" do
    Given "different versions"
    base = { name: "boost", integration: :cmake, group: :app, version: "1.90.0", hash: "SHA256=deadbeef", metadata: {} }

    When
    dep_a = Dev::Deps::Dependency.new(**base)
    dep_b = Dev::Deps::Dependency.new(**base.merge(version: "2.0.0"))

    Then
    dep_a != dep_b
  end

  test "metadata defaults to empty hash when nil" do
    When "nil metadata is passed"
    dep = Dev::Deps::Dependency.new(
      name: "luaunit",
      integration: :luarocks,
      group: :test,
      version: "3.5-1",
      hash: "SHA256=abc",
      metadata: nil,
    )

    Then
    dep.metadata.nil?
  end

  test "dependency can be deconstructed to a hash" do
    Given "a fully-populated dependency"
    dep = Dev::Deps::Dependency.new(
      name: "boost",
      integration: :cmake,
      group: :app,
      version: "1.90.0",
      hash: "SHA256=deadbeef",
      metadata: { url: "https://example.com/boost.tar.gz" },
    )

    When
    h = dep.to_h

    Then
    h[:name] == "boost"
    h[:integration] == :cmake
    h[:group] == :app
    h[:version] == "1.90.0"
    h[:hash] == "SHA256=deadbeef"
    h[:metadata] == { url: "https://example.com/boost.tar.gz" }
  end

  test "dependencies field stores transitive deps" do
    Given "a dependency with transitive deps"
    transitive = [{ name: "zlib", constraint: ">=1.0" }]

    When
    dep = Dev::Deps::Dependency.new(
      name: "boost",
      integration: :cmake,
      group: :app,
      version: "1.90.0",
      hash: "SHA256=deadbeef",
      metadata: {},
      dependencies: transitive,
    )

    Then
    dep.dependencies == transitive
  end
end
