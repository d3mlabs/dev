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

    Expect
    config.name == "project-name"
  end

  test "#commands returns the commands hash" do
    Given "a config with commands"
    cmd = Dev::ShellCommand.new(run: "./bin/up.rb", desc: "Up")
    config = Dev::Config.new(name: "project-name", commands: { "up" => cmd })

    Expect
    config.commands["up"] == cmd
  end

  test "#commands returns empty hash when no commands defined" do
    Given "a config with no commands"
    config = Dev::Config.new(name: "dev", commands: {})

    Expect
    config.commands == {}
  end

  test "print_usage with empty commands writes no-commands message" do
    Given "a Config with no commands"
    config = Dev::Config.new(name: "dev", commands: {})
    out = StringIO.new

    When "we print usage"
    config.print_usage(out: out)

    Then "no commands message is present"
    out.string.include?("(no commands defined in dev.yml)")
  end

  test "print_usage with commands writes each command and description" do
    Given "a Config with commands"
    config = Dev::Config.new(
      name: "dev",
      commands: {
        "up" => Dev::ShellCommand.new(run: "./bin/up.rb", desc: "Setup"),
        "test" => Dev::ShellCommand.new(run: "rspec", desc: "Run tests")
      }
    )
    out = StringIO.new

    When "we print usage"
    config.print_usage(out: out)

    Then "each command name and desc appears"
    out.string.include?("Usage: dev <command> [args...]")
    out.string.include?("Commands for dev:")
    out.string.include?("up")
    out.string.include?("Setup")
    out.string.include?("test")
    out.string.include?("Run tests")
  end
end
