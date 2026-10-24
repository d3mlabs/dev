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

  test "under: a need's scope placed under its user's takes the user's group and narrows host and env" do
    Given "a need gated #{need_host.inspect}/#{need_env.inspect} under a user scoped #{parent_host.inspect}/#{parent_env.inspect}"
    need = Dev::Deps::Scope.new(group: :app, host: need_host, env: need_env)
    parent = Dev::Deps::Scope.new(group: :editor, host: parent_host, env: parent_env)

    When "placing the need under the user"
    result = need.under(parent)

    Then "the group is the user's; each axis is whichever side is narrower"
    result == Dev::Deps::Scope.new(group: :editor, host: expected_host, env: expected_env)

    Where
    need_host | need_env | parent_host | parent_env | expected_host | expected_env
    nil       | nil      | nil         | nil        | nil           | nil
    :darwin   | nil      | nil         | nil        | :darwin       | nil
    nil       | nil      | :darwin     | "ci"       | :darwin       | "ci"
    :darwin   | "dev"    | :darwin     | nil        | :darwin       | "dev"
  end

  test "under: disjoint hosts or envs have no intersection — the need does not apply" do
    Given "a need and a user gated to different #{axis}"
    need = Dev::Deps::Scope.new(**need_axes)
    parent = Dev::Deps::Scope.new(**parent_axes)

    Expect
    need.under(parent).nil?

    Where
    axis    | need_axes          | parent_axes
    "hosts" | { host: :darwin }  | { host: :linux }
    "envs"  | { env: "ci" }      | { env: "dev" }
  end
end
