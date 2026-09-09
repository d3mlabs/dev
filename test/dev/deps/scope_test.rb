# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/scope"

transform!(RSpock::AST::Transformation)
class Dev::Deps::ScopeTest < Minitest::Test
  test "defaults to the app group, all hosts, all envs" do
    Given "a scope with no explicit context"
    scope = Dev::Deps::Scope.new

    Expect "group defaults and host/env are the all-encompassing empty form"
    scope.group == :app
    scope.host.nil?
    scope.env.nil?
  end

  test "coerces host to a symbol and env to a string at construction" do
    Given "a scope built from DSL-flavored inputs"
    scope = Dev::Deps::Scope.new(group: :build, host: "darwin", env: :ci)

    Expect
    scope.group == :build
    scope.host == :darwin
    scope.env == "ci"
  end

  test "is value-equal, so inherited scopes compare cleanly" do
    Given "two scopes built independently from the same context"
    a = Dev::Deps::Scope.new(group: :build, host: :linux, env: "ci")
    b = Dev::Deps::Scope.new(group: :build, host: :linux, env: "ci")

    Expect
    a == b
    { a => 1 }.key?(b)
  end

  test "projects host and env into install-scoping metadata" do
    Given "a fully-pinned scope"
    scope = Dev::Deps::Scope.new(group: :build, host: :darwin, env: "ci")

    Expect "host and env serialize; group does not (it is a first-class pin field)"
    scope.to_metadata == { "host" => "darwin", "env" => "ci" }
  end

  test "projects nothing for the all-hosts, all-envs scope" do
    Given "a default scope"
    scope = Dev::Deps::Scope.new(group: :game)

    Expect "the projection is empty — no absent keys smuggled in"
    scope.to_metadata == {}
  end
end
