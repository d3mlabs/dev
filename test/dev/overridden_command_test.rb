# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/overridden_command"
require "dev/builtin_command"

transform!(RSpock::AST::Transformation)
class Dev::OverriddenCommandTest < Minitest::Test
  test "execute calls super first, then body" do
    Given "an overridden command with two recording blocks"
    order = []
    super_cmd = Dev::BuiltinCommand.new(desc: "super") { |args, context| order << :super }
    body_cmd = Dev::BuiltinCommand.new(desc: "body") { |args, context| order << :body }
    cmd = Dev::OverriddenCommand.new(super_command: super_cmd, body: body_cmd)

    When "executing"
    cmd.execute(args: [], context: nil)

    Then "super ran first, then body"
    order == [:super, :body]
  end

  test "desc delegates to the overriding body" do
    Given "an overridden command"
    super_cmd = Dev::BuiltinCommand.new(desc: "Resolve deps") { |args, context| }
    body_cmd = Dev::BuiltinCommand.new(desc: "Project setup") { |args, context| }
    cmd = Dev::OverriddenCommand.new(super_command: super_cmd, body: body_cmd)

    Expect "the override owns the slot, so its desc wins"
    cmd.desc == "Project setup"
  end

  test "execute passes args and context through to both" do
    Given "an overridden command that records args and context"
    received = []
    super_cmd = Dev::BuiltinCommand.new { |args, context| received << { from: :super, args: args, context: context } }
    body_cmd = Dev::BuiltinCommand.new { |args, context| received << { from: :body, args: args, context: context } }
    cmd = Dev::OverriddenCommand.new(super_command: super_cmd, body: body_cmd)

    When "executing with specific args and context"
    cmd.execute(args: ["--verbose"], context: :test_ctx)

    Then "both received the same args and context"
    received.size == 2
    received[0] == { from: :super, args: ["--verbose"], context: :test_ctx }
    received[1] == { from: :body, args: ["--verbose"], context: :test_ctx }
  end
end
