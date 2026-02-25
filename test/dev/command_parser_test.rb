# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command"
require "dev/command_parser"

transform!(RSpock::AST::Transformation)
class CommandParserTest < Minitest::Test
  extend T::Sig

  test "parse with full hash returns Command with correct attributes" do
    Given "a command hash with run, desc, and interactive"
    parser = Dev::CommandParser.new
    hash = { "run" => "./bin/setup.rb", "desc" => "Setup", "interactive" => true }

    When "we parse it"
    cmd = parser.parse(cmd_hash: hash)

    Then "we get a Command with those values"
    assert_equal "./bin/setup.rb", cmd.run
    assert_equal "Setup", cmd.desc
    assert_equal true, cmd.interactive
  end

  test "parse with only run uses default desc and interactive false" do
    Given "a command hash with only run"
    parser = Dev::CommandParser.new
    hash = { "run" => "rspec" }

    When "we parse it"
    cmd = parser.parse(cmd_hash: hash)

    Then "desc defaults and interactive is false"
    assert_equal "rspec", cmd.run
    assert_equal "(no description)", cmd.desc
    assert_equal false, cmd.interactive
  end

  test "parse with missing run raises ArgumentError" do
    Given "a command hash without run"
    parser = Dev::CommandParser.new
    hash = { "desc" => "No run" }

    Expect "parse raises ArgumentError"
    assert_raises(ArgumentError) { parser.parse(cmd_hash: hash) }
  end

  test "parse with empty run raises ArgumentError" do
    Given "a command hash with empty run"
    parser = Dev::CommandParser.new
    hash = { "run" => "" }

    Expect "parse raises ArgumentError"
    assert_raises(ArgumentError) { parser.parse(cmd_hash: hash) }
  end

  test "parse with nil desc uses default description" do
    Given "a command hash with run and nil desc"
    parser = Dev::CommandParser.new
    hash = { "run" => "./bin/up.rb", "desc" => nil }

    When "we parse it"
    cmd = parser.parse(cmd_hash: hash)

    Then "desc is the default"
    assert_equal "(no description)", cmd.desc
  end

  test "parse with interactive false or missing is false" do
    Given "a command hash with interactive false"
    parser = Dev::CommandParser.new
    hash = { "run" => "./bin/up.rb", "interactive" => false }

    When "we parse it"
    cmd = parser.parse(cmd_hash: hash)

    Then "interactive is false"
    assert_equal false, cmd.interactive

    # When "hash has no interactive key"
    # cmd2 = parser.parse(cmd_hash: { "run" => "./bin/up.rb" })

    # Then "interactive is false"
    # assert_equal false, cmd2.interactive
  end
end
