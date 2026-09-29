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
    cmd = parser.parse(["cmd"], hash)

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
    cmd = parser.parse(["cmd"], hash)

    Then "desc defaults and repl is false"
    cmd.run == "rspec"
    cmd.desc == "(no description)"
    cmd.repl == false
  end

  test "parse with neither run nor commands raises MissingBodyError naming the command" do
    Given "a command hash without run"
    parser = Dev::CommandParser.new
    hash = { "desc" => "No run" }

    When "parsing the command"
    error = assert_raises(Dev::CommandParser::MissingBodyError) { parser.parse(["cmd"], hash) }

    Then "the error names the command and both accepted keys"
    error.message.include?("'cmd'")
    error.message.include?("'run'")
    error.message.include?("'commands'")
  end

  test "parse with empty run raises MissingBodyError (an ArgumentError at the CLI boundary)" do
    Given "a command hash with empty run"
    parser = Dev::CommandParser.new
    hash = { "run" => "" }

    When "parsing the command"
    parser.parse(["cmd"], hash)

    Then "it raises the typed error, mapped like any ArgumentError"
    raises ArgumentError
  end

  test "parse with commands and no run returns a project CommandGroup at the entry's path" do
    Given "a command hash with commands and no run"
    parser = Dev::CommandParser.new
    hash = {
      "desc" => "Test suites",
      "hidden" => true,
      "commands" => {
        "unit" => { "run" => "rspec spec/unit", "desc" => "Unit" },
        "e2e" => { "run" => "./bin/e2e.sh", "hidden" => true },
      },
    }

    When "we parse it"
    group = parser.parse(["test"], hash)

    Then "we get a group with parsed children in declaration order"
    group == Dev::CommandGroup.new(
      path: ["test"],
      desc: "Test suites",
      category: Dev::Command::Category::Project,
      hidden: true,
      children: {
        "unit" => Dev::ProjectCommand.new(run: "rspec spec/unit", desc: "Unit"),
        "e2e" => Dev::ProjectCommand.new(run: "./bin/e2e.sh", hidden: true),
      },
    )
    group.children.keys == ["unit", "e2e"]
  end

  test "parse with run and commands returns a ProjectCommand heading its children" do
    Given "a command hash with both run and commands"
    parser = Dev::CommandParser.new
    hash = {
      "run" => "./bin/test.sh",
      "desc" => "All tests",
      "container" => false,
      "hidden" => true,
      "commands" => { "unit" => { "run" => "rspec" } },
    }

    When "we parse it"
    cmd = parser.parse(["test"], hash)

    Then "it is the command the bare invocation runs, with the nested entries as children"
    cmd == Dev::ProjectCommand.new(
      run: "./bin/test.sh",
      desc: "All tests",
      container: false,
      hidden: true,
      children: { "unit" => Dev::ProjectCommand.new(run: "rspec") },
    )
  end

  test "parse nests to any depth, each group carrying its full path" do
    Given "a two-level tree"
    parser = Dev::CommandParser.new
    hash = { "commands" => { "unit" => { "commands" => { "fast" => { "run" => "rspec --tag fast" } } } } }

    When "we parse it"
    group = parser.parse(["test"], hash)

    Then "the inner group parsed with its own children and path"
    inner = group.children.fetch("unit")
    inner.is_a?(Dev::CommandGroup)
    inner.path == ["test", "unit"]
    inner.children.fetch("fast").run == "rspec --tag fast"
  end

  test "parse with an empty commands mapping treats it as absent" do
    Given "a leaf with an empty commands key"
    parser = Dev::CommandParser.new
    hash = { "run" => "rspec", "commands" => {} }

    When "we parse it"
    cmd = parser.parse(["test"], hash)

    Then "it is a plain leaf"
    cmd == Dev::ProjectCommand.new(run: "rspec")
  end

  test "parse rejects repl beside commands: a REPL cannot dispatch subcommands" do
    Given "a command hash with run, commands and repl"
    parser = Dev::CommandParser.new
    hash = { "run" => "irb", "repl" => true, "commands" => { "unit" => { "run" => "rspec" } } }

    When "we parse it"
    parser.parse(["console"], hash)

    Then
    raises Dev::CommandParser::ReplGroupError
  end

  test "parse rejects a child named help: help is the tree's reserved introspection word" do
    Given "a group with a help child"
    parser = Dev::CommandParser.new
    hash = { "commands" => { "help" => { "run" => "echo" } } }

    When "we parse it"
    parser.parse(["test"], hash)

    Then
    raises Dev::CommandParser::ReservedChildNameError
  end

  test "parse rejects a commands value that is not a mapping" do
    Given "a commands key holding a list"
    parser = Dev::CommandParser.new
    hash = { "commands" => ["unit"] }

    When "we parse it"
    parser.parse(["test"], hash)

    Then
    raises Dev::CommandParser::InvalidCommandsError
  end

  test "a nested error names the full command path" do
    Given "a nested child with no body"
    parser = Dev::CommandParser.new
    hash = { "commands" => { "unit" => { "desc" => "nothing to run" } } }

    When "we parse it"
    error = assert_raises(Dev::CommandParser::MissingBodyError) { parser.parse(["test"], hash) }

    Then "the path reads as the user would type it"
    error.message.include?("'test unit'")
  end

  test "parse with nil desc uses default description" do
    Given "a command hash with run and nil desc"
    parser = Dev::CommandParser.new
    hash = { "run" => "./bin/up.rb", "desc" => nil }

    When "we parse it"
    cmd = parser.parse(["cmd"], hash)

    Then "desc is the default"
    cmd.desc == "(no description)"
  end

  test "parse with repl false is false" do
    Given "a command hash with repl false"
    parser = Dev::CommandParser.new
    hash = { "run" => "./bin/up.rb", "repl" => false }

    When "we parse it"
    cmd = parser.parse(["cmd"], hash)

    Then "repl is false"
    cmd.repl == false
  end

  test "parse defaults container to true" do
    Given "a command hash without container"
    parser = Dev::CommandParser.new
    hash = { "run" => "./bin/build.sh" }

    When "we parse it"
    cmd = parser.parse(["cmd"], hash)

    Then
    cmd.container == true
  end

  test "parse with container false sets container to false" do
    Given "a command hash with container: false"
    parser = Dev::CommandParser.new
    hash = { "run" => "./bin/deploy.sh", "container" => false }

    When "we parse it"
    cmd = parser.parse(["cmd"], hash)

    Then
    cmd.container == false
  end

  test "parse with container true sets container to true" do
    Given "a command hash with container: true"
    parser = Dev::CommandParser.new
    hash = { "run" => "./bin/build.sh", "container" => true }

    When "we parse it"
    cmd = parser.parse(["cmd"], hash)

    Then
    cmd.container == true
  end

  test "parse defaults hidden to false" do
    Given "a command hash without hidden"
    parser = Dev::CommandParser.new
    hash = { "run" => "./bin/build.sh" }

    When "we parse it"
    cmd = parser.parse(["cmd"], hash)

    Then
    cmd.hidden? == false
  end

  test "parse with hidden true marks the command hidden" do
    Given "a command hash with hidden: true"
    parser = Dev::CommandParser.new
    hash = { "run" => "./bin/build.sh", "hidden" => true }

    When "we parse it"
    cmd = parser.parse(["cmd"], hash)

    Then
    cmd.hidden? == true
  end
end
