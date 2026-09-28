# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/help_command"
require "pathname"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::HelpCommandTest < Minitest::Test
  include SorbetHelper

  test "traits: visible, staleness-exempt (help must work while stale), never stamps, workflow group" do
    Given "the builtin"
    command = build_help

    Expect "the declarative traits"
    command.hidden? == false
    command.staleness_exempt? == true
    command.stamps? == false
    command.category == Dev::Command::Category::Workflow
    command.desc == "Show this usage"
  end

  test "call renders usage through the printer with the provider's listing" do
    Given "a printer expecting the provider's commands"
    commands = { "test" => Dev::ProjectCommand.new(run: "rspec", desc: "Run tests") }
    out = StringIO.new
    usage_printer = typed_mock(Dev::Cli::UsagePrinter)
    usage_printer.expects(:print).with(project_name: "myproject", commands: commands, out: out).once
    command = build_help(
      project_name: "myproject", usage_printer: usage_printer, out: out,
      commands_provider: -> { commands },
    )

    When "running help"
    command.call(args: [], context: build_context)

    Then "the printer expectation holds"
    true
  end

  test "the listing is consulted at call time, not construction time" do
    Given "a provider over a catalog assigned only after help is constructed"
    catalog = nil
    printed = []
    usage_printer = typed_mock(Dev::Cli::UsagePrinter)
    usage_printer.stubs(:print).with { |commands:, **| printed << commands }
    command = build_help(usage_printer: usage_printer, commands_provider: -> { catalog })
    catalog = { "up" => Dev::ProjectCommand.new(run: "./bin/up.rb", desc: "Setup") }

    When "running help"
    command.call(args: [], context: build_context)

    Then "the late-assigned catalog is what renders"
    printed.fetch(0) == catalog
  end

  test "help <path> renders the group's usage when the path reaches a group" do
    Given "a two-level tree and a printer expecting the inner group"
    inner = build_group(["test", "unit"], children: { "fast" => Dev::ProjectCommand.new(run: "rspec") })
    outer = build_group(["test"], children: { "unit" => inner })
    out = StringIO.new
    usage_printer = typed_mock(Dev::Cli::UsagePrinter)
    usage_printer.expects(:print_group).with(group: inner, out: out).once
    command = build_help(usage_printer: usage_printer, out: out, commands_provider: -> { { "test" => outer } })

    When "asking for help on the nested path"
    command.call(args: ["test", "unit"], context: build_context)

    Then "the printer expectation holds"
    true
  end

  test "help <path> on a leaf prints its invocation and description" do
    Given "a leaf under a group"
    leaf = Dev::ProjectCommand.new(run: "rspec", desc: "Unit tests")
    out = StringIO.new
    command = build_help(out: out, commands_provider: -> { { "test" => build_group(["test"], children: { "unit" => leaf }) } })

    When "asking for help on the leaf"
    command.call(args: ["test", "unit"], context: build_context)

    Then "the leaf's one-line usage renders"
    out.string == "Usage: dev test unit [args...]\n\nUnit tests\n"
  end

  test "help <path> on an unknown path raises UnknownCommandError naming the path" do
    Given "a catalog without the asked name"
    command = build_help(commands_provider: -> { { "up" => Dev::ProjectCommand.new(run: "x") } })

    When "asking for help on a missing path"
    error = assert_raises(Dev::Builtins::HelpCommand::UnknownCommandError) do
      command.call(args: ["up", "nope"], context: build_context)
    end

    Then
    error.message.include?("'up nope'")
  end

  private

  def build_group(path, children:)
    Dev::CommandGroup.new(path: path, desc: "group", category: Dev::Command::Category::Project, children: children)
  end

  def build_help(project_name: "testproject", usage_printer: typed_mock(Dev::Cli::UsagePrinter),
    out: StringIO.new, commands_provider: -> { {} })
    Dev::Builtins::HelpCommand.new(project_name:, usage_printer:, out:, commands_provider:)
  end

  def build_context
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(name: "TestProject", root: Pathname.new("/tmp/help-test"), ruby_version: "4.0.1"),
    )
  end
end
