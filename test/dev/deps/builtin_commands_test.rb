# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/builtin_commands"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BuiltinCommandsTest < Minitest::Test
  test "COMMANDS includes update-deps" do
    Expect
    Dev::Deps::BuiltinCommands::COMMANDS.include?("update-deps")
  end

  test "builtin? returns true for update-deps" do
    Expect
    Dev::Deps::BuiltinCommands.builtin?("update-deps")
  end

  test "builtin? returns false for arbitrary commands" do
    Expect
    !Dev::Deps::BuiltinCommands.builtin?("test")
  end
end
