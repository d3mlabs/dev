# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command"
require "dev/project_command_group"

transform!(RSpock::AST::Transformation)
class Dev::ProjectCommandGroupTest < Minitest::Test
  test "a group holds its children, desc, own leaf, and hidden flag" do
    Given "a runnable, hidden group"
    own = Dev::ProjectCommand.new(run: "./bin/test.sh", desc: "All tests")
    unit = Dev::ProjectCommand.new(run: "rspec")
    group = Dev::ProjectCommandGroup.new(children: { "unit" => unit }, desc: "All tests", own: own, hidden: true)

    Expect "every declared attribute reads back"
    group.children == { "unit" => unit }
    group.desc == "All tests"
    group.own == own
    group.hidden?
  end

  test "desc, own, and hidden default to the leaf's defaults" do
    Given "a pure group with only children"
    group = Dev::ProjectCommandGroup.new(children: { "unit" => Dev::ProjectCommand.new(run: "rspec") })

    Expect
    group.desc == "(no description)"
    group.own.nil?
    !group.hidden?
  end

  test "ProjectCommandGroup is final: subclassing raises" do
    When "declaring a subclass"
    Class.new(Dev::ProjectCommandGroup)

    Then
    raises RuntimeError
  end

  test "#== and #hash agree for #{label}" do
    Given "a reference group"
    reference = Dev::ProjectCommandGroup.new(
      children: { "unit" => Dev::ProjectCommand.new(run: "rspec") }, desc: "d",
    )

    Expect "value semantics: equal groups hash alike, unequal ones differ"
    (reference == other) == expected
    reference.eql?(other) == expected
    (reference.hash == other.hash) == expected

    Where
    label | other | expected
    "an identical group" | Dev::ProjectCommandGroup.new(children: { "unit" => Dev::ProjectCommand.new(run: "rspec") }, desc: "d") | true
    "a different child" | Dev::ProjectCommandGroup.new(children: { "unit" => Dev::ProjectCommand.new(run: "minitest") }, desc: "d") | false
    "a different desc" | Dev::ProjectCommandGroup.new(children: { "unit" => Dev::ProjectCommand.new(run: "rspec") }, desc: "e") | false
    "an own leaf added" | Dev::ProjectCommandGroup.new(children: { "unit" => Dev::ProjectCommand.new(run: "rspec") }, desc: "d", own: Dev::ProjectCommand.new(run: "x")) | false
    "hidden flipped" | Dev::ProjectCommandGroup.new(children: { "unit" => Dev::ProjectCommand.new(run: "rspec") }, desc: "d", hidden: true) | false
  end

  test "#== is false against a non-group" do
    Given "a group"
    group = Dev::ProjectCommandGroup.new(children: { "unit" => Dev::ProjectCommand.new(run: "rspec") })

    Expect
    group != "not a group"
    !group.eql?(nil)
  end
end
