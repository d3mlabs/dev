# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtin_command"

transform!(RSpock::AST::Transformation)
class Dev::BuiltinCommandTest < Minitest::Test
  test "execute calls the block with args and context" do
    Given "a builtin command with a recording block"
    received = {}
    cmd = Dev::BuiltinCommand.new(desc: "test command") do |args, context|
      received[:args] = args
      received[:context] = context
    end

    When "executing"
    cmd.execute(args: ["--verbose"], context: :fake_context)

    Then "block received args and context"
    received[:args] == ["--verbose"]
    received[:context] == :fake_context
  end

  test "desc returns the description" do
    Given "a builtin command"
    cmd = Dev::BuiltinCommand.new(desc: "Resolve deps") {}

    Expect
    cmd.desc == "Resolve deps"
  end

  test "desc defaults to no description" do
    Given "a builtin command without desc"
    cmd = Dev::BuiltinCommand.new { |args, context| }

    Expect
    cmd.desc == "(no description)"
  end
end
