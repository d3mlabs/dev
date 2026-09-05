# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/dependency_edge"

transform!(RSpock::AST::Transformation)
class Dev::Deps::DependencyEdgeTest < Minitest::Test
  test "keeps a string constraint exactly as upstream reported it" do
    Given "an edge from a service that expresses constraints as strings"
    edge = Dev::Deps::DependencyEdge.new(name: "lua", constraint: ">= 5.1")

    Expect "no normalization happens here — that is the Resolver's job"
    edge.name == "lua"
    edge.constraint == ">= 5.1"
  end

  test "keeps a hash constraint exactly as upstream reported it" do
    Given "an edge from a service that expresses constraints as hashes"
    edge = Dev::Deps::DependencyEdge.new(name: "lpeg", constraint: { "version" => "~> 1.0" })

    Expect
    edge.constraint == { "version" => "~> 1.0" }
  end

  test "an edge can pin nothing" do
    Given "an unconstrained edge"
    edge = Dev::Deps::DependencyEdge.new(name: "openssl", constraint: nil)

    Expect
    edge.constraint.nil?
  end

  test "is value-equal" do
    Given "two edges with the same name and constraint"
    a = Dev::Deps::DependencyEdge.new(name: "lua", constraint: ">= 5.1")
    b = Dev::Deps::DependencyEdge.new(name: "lua", constraint: ">= 5.1")

    Expect
    a == b
    a.hash == b.hash
  end
end
