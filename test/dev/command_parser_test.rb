# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command"
require "dev/command_parser"

transform!(RSpock::AST::Transformation)
class CommandParserTest < Minitest::Test
  extend T::Sig

  test "parse with full hash returns Command with correct attributes" do
    Given "a command hash with run, desc, and repl"
    parser = Dev::CommandParser.new
    hash = { "run" => "./bin/setup.rb", "desc" => "Setup", "repl" => true }

    When "we parse it"
    cmd = parser.parse(hash)

    Then "we get a Command with those values"
    cmd.run == "./bin/setup.rb"
    cmd.desc == "Setup"
    cmd.repl == true
  end

  test "parse with only run uses default desc and repl false" do
    Given "a command hash with only run"
    parser = Dev::CommandParser.new
    hash = { "run" => "rspec" }

    When "we parse it"
    cmd = parser.parse(hash)

    Then "desc defaults and repl is false"
    cmd.run == "rspec"
    cmd.desc == "(no description)"
    cmd.repl == false
  end

  test "parse with missing run raises ArgumentError" do
    Given "a command hash without run"
    parser = Dev::CommandParser.new
    hash = { "desc" => "No run" }

    When "parsing the command"
    parser.parse(hash)

    Then "it raises ArgumentError"
    raises ArgumentError
  end

  test "parse with empty run raises ArgumentError" do
    Given "a command hash with empty run"
    parser = Dev::CommandParser.new
    hash = { "run" => "" }

    When "parsing the command"
    parser.parse(hash)

    Then "it raises ArgumentError"
    raises ArgumentError
  end

  test "parse with nil desc uses default description" do
    Given "a command hash with run and nil desc"
    parser = Dev::CommandParser.new
    hash = { "run" => "./bin/up.rb", "desc" => nil }

    When "we parse it"
    cmd = parser.parse(hash)

    Then "desc is the default"
    cmd.desc == "(no description)"
  end

  test "parse with repl false is false" do
    Given "a command hash with repl false"
    parser = Dev::CommandParser.new
    hash = { "run" => "./bin/up.rb", "repl" => false }

    When "we parse it"
    cmd = parser.parse(hash)

    Then "repl is false"
    cmd.repl == false
  end
end
