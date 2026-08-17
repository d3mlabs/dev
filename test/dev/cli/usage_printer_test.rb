# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/usage_printer"
require "dev/command"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Cli::UsagePrinterTest < Minitest::Test
  test "show_usage? triggers on empty argv and both help flags only" do
    Given "the printer"
    printer = Dev::Cli::UsagePrinter.new

    Expect "the usage triggers"
    printer.show_usage?([]) == true
    printer.show_usage?(["--help"]) == true
    printer.show_usage?(["-h"]) == true
    printer.show_usage?(["test"]) == false
    printer.show_usage?(["test", "--help"]) == false
  end

  test "print lists each visible command with its description" do
    Given "two commands to advertise"
    printer = Dev::Cli::UsagePrinter.new
    commands = {
      "up" => Dev::ProjectCommand.new(run: "./bin/up.rb", desc: "Setup"),
      "test" => Dev::ProjectCommand.new(run: "rspec", desc: "Run tests"),
    }
    out = StringIO.new

    When "printing usage"
    printer.print(project_name: "myproject", commands: commands, out: out)

    Then "the header, both commands, and the examples line all render"
    out.string.include?("Usage: dev <command> [args...]")
    out.string.include?("Commands for myproject:")
    out.string.include?("up")
    out.string.include?("Setup")
    out.string.include?("test")
    out.string.include?("Run tests")
    out.string.include?("Examples:")
  end

  test "print reports a project with no commands" do
    Given "an empty command set"
    printer = Dev::Cli::UsagePrinter.new
    out = StringIO.new

    When "printing usage"
    printer.print(project_name: "bareproject", commands: {}, out: out)

    Then "the empty state is explicit"
    out.string.include?("(no commands defined)")
  end
end
