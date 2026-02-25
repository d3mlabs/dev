# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command"
require "dev/config"
require "stringio"

transform!(RSpock::AST::Transformation)
class ConfigTest < Minitest::Test
  extend T::Sig

  test "#name returns the config name" do
    Given "a config with a name"
    config = Dev::Config.new(name: "project-name", commands: {})

    Expect "#name returns the correct name"
    config.name == "project-name"
  end

  test "#command returns the command for a given name" do
    Given "a config with an 'up' command"
    cmd = Dev::Command.new(run: "./bin/up.rb", desc: "Up")
    config = Dev::Config.new(name: "project-name", commands: { "up" => cmd })

    Expect "#command retrieves the correct command by name"
    config.command("up") == cmd
  end

  test "#command raises KeyError for unknown command name" do
    Given "a Config"
    config = Dev::Config.new(
      name: "dev",
      commands: { "up" => Dev::Command.new(run: "./bin/up.rb") }
    )

    Expect "fetching an unknown command raises a KeyError"
    assert_raises KeyError do
      config.command("unknown")
    end
  end

  test "print_usage with empty commands writes no-commands message" do
    Given "a Config with no commands"
    config = Dev::Config.new(name: "dev", commands: {})
    out = StringIO.new

    When "we print usage to out"
    config.print_usage(out: out)

    Then "no commands message is written"
    assert_includes(out.string, "(no commands defined in dev.yml)")
  end

  test "print_usage with commands writes each command and description" do
    Given "a Config with commands"
    config = Dev::Config.new(
      name: "dev",
      commands: {
        "command_name_1" => Dev::Command.new(run: "./command_1.rb", desc: "Command 1"),
        "command_name_2" => Dev::Command.new(run: "./command_2.rb", desc: "Command 2")
      }
    )
    out = StringIO.new

    When "we print usage to out"
    config.print_usage(out: out)

    Then "each command name and desc appears"
    assert_includes out.string, "Usage: dev <command> [args...]"
    assert_includes out.string, "Commands for dev:"
    assert_includes out.string, "command_name_1"
    assert_includes out.string, "Command 1"
    assert_includes out.string, "command_name_2"
    assert_includes out.string, "Command 2"
  end
end
