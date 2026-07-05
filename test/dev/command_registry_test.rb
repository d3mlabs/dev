# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command_registry"
require "dev/command"
require "dev/builtin_command"
require "dev/overridden_command"

transform!(RSpock::AST::Transformation)
class Dev::CommandRegistryTest < Minitest::Test
  test "register BuiltinCommand creates a virtual slot" do
    Given "a registry with a built-in command"
    registry = Dev::CommandRegistry.new
    cmd = Dev::BuiltinCommand.new(desc: "resolve deps") {}
    registry.register("update-deps", cmd)

    Expect "lookup returns the built-in"
    registry.lookup("update-deps") == cmd
  end

  test "register ShellCommand creates a final slot" do
    Given "a registry with a shell command"
    registry = Dev::CommandRegistry.new
    cmd = Dev::ShellCommand.new(run: "./bin/test.sh", desc: "Run tests")
    registry.register("test", cmd)

    Expect "lookup returns the shell command"
    registry.lookup("test") == cmd
  end

  test "register ShellCommand into virtual slot creates OverriddenCommand" do
    Given "a registry with a built-in, then a shell override"
    registry = Dev::CommandRegistry.new
    builtin = Dev::BuiltinCommand.new(desc: "built-in up") { |args, context| }
    shell = Dev::ShellCommand.new(run: "./bin/up.sh", desc: "project up")
    registry.register("up", builtin)
    registry.register("up", shell)

    When "looking up the resolved command"
    resolved = registry.lookup("up")

    Then "it is an OverriddenCommand with the override's desc"
    resolved.is_a?(Dev::OverriddenCommand)
    resolved.desc == "project up"
  end

  test "register into final slot raises DuplicateCommandError" do
    Given "a registry with a final shell command"
    registry = Dev::CommandRegistry.new
    registry.register("test", Dev::ShellCommand.new(run: "rspec"))

    When "registering another command with same name"
    registry.register("test", Dev::ShellCommand.new(run: "rake test"))

    Then
    raises Dev::CommandRegistry::DuplicateCommandError
  end

  test "register into already-overridden slot raises DuplicateCommandError" do
    Given "a registry where a built-in has already been overridden"
    registry = Dev::CommandRegistry.new
    registry.register("up", Dev::BuiltinCommand.new(desc: "builtin") { |args, context| })
    registry.register("up", Dev::ShellCommand.new(run: "./bin/up.sh", desc: "project"))

    When "registering a third command into the sealed slot"
    registry.register("up", Dev::ShellCommand.new(run: "./bin/up2.sh", desc: "another"))

    Then
    raises Dev::CommandRegistry::DuplicateCommandError
  end

  test "lookup raises CommandNotFoundError for unknown name" do
    Given "an empty registry"
    registry = Dev::CommandRegistry.new

    When "looking up a nonexistent command"
    registry.lookup("nope")

    Then
    raises Dev::CommandRegistry::CommandNotFoundError
  end

  test "all returns resolved leaf commands" do
    Given "a registry with built-in, shell, and overridden commands"
    registry = Dev::CommandRegistry.new
    builtin = Dev::BuiltinCommand.new(desc: "resolve") {}
    shell = Dev::ShellCommand.new(run: "rspec", desc: "test")
    override = Dev::ShellCommand.new(run: "./bin/up.sh", desc: "project up")

    registry.register("update-deps", builtin)
    registry.register("test", shell)
    registry.register("update-deps", override)

    When "listing all commands"
    commands = registry.all

    Then "returns two entries with resolved commands"
    commands.size == 2
    commands.key?("update-deps")
    commands.key?("test")
    commands["test"] == shell
    # The override owns the slot, so its desc wins in listings.
    commands["update-deps"].desc == "project up"
  end
end
