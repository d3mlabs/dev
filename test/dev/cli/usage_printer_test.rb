# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/usage_printer"
require "dev/command"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Cli::UsagePrinterTest < Minitest::Test
  # Minimal builtin fake: the printer only reads desc and category, so the
  # fake carries just those traits.
  class FakeBuiltin < Dev::BuiltinCommand
    def initialize(desc:, category:)
      super()
      @desc = desc
      @category = category
    end

    attr_reader :desc, :category

    def call(args:, context:); end
  end

  def lifecycle_builtin(desc: "a lifecycle builtin")
    FakeBuiltin.new(desc: desc, category: Dev::Command::Category::Lifecycle)
  end

  def workflow_builtin(desc: "a workflow builtin")
    FakeBuiltin.new(desc: desc, category: Dev::Command::Category::Workflow)
  end

  test "print renders the three sections in fixed order with their commands" do
    Given "one command per usage group"
    printer = Dev::Cli::UsagePrinter.new
    commands = {
      "up" => lifecycle_builtin(desc: "Provision"),
      "help" => workflow_builtin(desc: "Show this usage"),
      "test" => Dev::ProjectCommand.new(run: "rspec", desc: "Run tests"),
    }
    out = StringIO.new

    When "printing usage"
    printer.print(project_name: "myproject", commands: commands, out: out)

    Then "each command renders under its section, sections in fixed order"
    lines = out.string.lines.map(&:chomp)
    lines.index("Commands for myproject:") < lines.index("  test         Run tests")
    lines.index("Lifecycle:") < lines.index("  up           Provision")
    lines.index("Development flow:") < lines.index("  help         Show this usage")
    lines.index("Commands for myproject:") < lines.index("Lifecycle:")
    lines.index("Lifecycle:") < lines.index("Development flow:")
    out.string.include?("Usage: dev <command> [args...]")
    out.string.include?("Examples:")
  end

  test "commands list alphabetically within a section" do
    Given "lifecycle commands registered out of alphabetical order"
    printer = Dev::Cli::UsagePrinter.new
    commands = {
      "update-deps" => lifecycle_builtin,
      "check" => lifecycle_builtin,
      "install-deps" => lifecycle_builtin,
    }
    out = StringIO.new

    When "printing usage"
    printer.print(project_name: "myproject", commands: commands, out: out)

    Then "the section lists them alphabetically"
    lines = out.string.lines.map(&:chomp)
    lines.index("  check        a lifecycle builtin") <
      lines.index("  install-deps a lifecycle builtin")
    lines.index("  install-deps a lifecycle builtin") <
      lines.index("  update-deps  a lifecycle builtin")
  end

  test "print reports a project with no commands of its own" do
    Given "a command set with only builtins"
    printer = Dev::Cli::UsagePrinter.new
    commands = { "help" => workflow_builtin }
    out = StringIO.new

    When "printing usage"
    printer.print(project_name: "bareproject", commands: commands, out: out)

    Then "the project section's empty state is explicit"
    out.string.include?("Commands for bareproject:")
    out.string.include?("(no commands defined)")
  end

  test "builtin sections without commands are omitted" do
    Given "a command set with no lifecycle commands"
    printer = Dev::Cli::UsagePrinter.new
    commands = { "test" => Dev::ProjectCommand.new(run: "rspec", desc: "Run tests") }
    out = StringIO.new

    When "printing usage"
    printer.print(project_name: "myproject", commands: commands, out: out)

    Then "no empty section headers render"
    !out.string.include?("Lifecycle:")
    !out.string.include?("Development flow:")
  end

  test "an overridden slot lists under the builtin's section with the project's desc" do
    Given "a lifecycle slot overridden by a project command"
    printer = Dev::Cli::UsagePrinter.new
    overridden = Dev::OverriddenCommand.new(
      builtin: lifecycle_builtin(desc: "builtin up"),
      project: Dev::ProjectCommand.new(run: "./bin/up.rb", desc: "Project setup"),
    )
    out = StringIO.new

    When "printing usage"
    printer.print(project_name: "myproject", commands: { "up" => overridden }, out: out)

    Then "the slot renders under Lifecycle with the override's description"
    lines = out.string.lines.map(&:chomp)
    lines.index("Lifecycle:") < lines.index("  up           Project setup")
    !out.string.include?("builtin up")
  end

  test "a group lists under its section with a trailing ellipsis marking it as a group" do
    Given "a lifecycle group"
    printer = Dev::Cli::UsagePrinter.new
    group = build_group(["deps"], category: Dev::Command::Category::Lifecycle, desc: "Dependency lookups")
    out = StringIO.new

    When "printing usage"
    printer.print(project_name: "myproject", commands: { "deps" => group }, out: out)

    Then "the marker tells the reader there is more beneath"
    lines = out.string.lines.map(&:chomp)
    lines.index("Lifecycle:") < lines.index("  deps …       Dependency lookups")
  end

  test "a runnable command with children lists with the same ellipsis marker" do
    Given "a project command heading a child"
    printer = Dev::Cli::UsagePrinter.new
    test = Dev::ProjectCommand.new(run: "./bin/test.sh", desc: "All tests", children: { "unit" => workflow_builtin })
    out = StringIO.new

    When "printing usage"
    printer.print(project_name: "myproject", commands: { "test" => test }, out: out)

    Then
    out.string.include?("  test …       All tests")
  end

  test "print_node renders a group's usage line and its visible children" do
    Given "a group with a hidden child"
    printer = Dev::Cli::UsagePrinter.new
    group = build_group(
      ["deps"],
      desc: "Dependency lookups",
      children: {
        "path" => lifecycle_builtin(desc: "Print a locked artifact's path"),
        "plumbing" => Dev::ProjectCommand.new(run: "x", desc: "internal", hidden: true),
        "check" => build_group(["deps", "check"], desc: "Checks"),
      },
    )
    out = StringIO.new

    When "printing the node"
    printer.print_node(path: ["deps"], command: group, out: out)

    Then "usage names the path, the desc follows, children list alphabetically, hidden ones omitted, groups marked"
    lines = out.string.lines.map(&:chomp)
    lines.fetch(0) == "Usage: dev deps <command> [args...]"
    lines.fetch(1) == ""
    lines.fetch(2) == "Dependency lookups"
    lines.index("Commands:") < lines.index("  check …      Checks")
    lines.index("  check …      Checks") < lines.index("  path         Print a locked artifact's path")
    !out.string.include?("plumbing")
  end

  test "print_node renders both invocations of a runnable command with children" do
    Given "a project command heading a child"
    printer = Dev::Cli::UsagePrinter.new
    test = Dev::ProjectCommand.new(
      run: "./bin/test.sh", desc: "Run every suite",
      children: { "unit" => Dev::ProjectCommand.new(run: "rspec", desc: "Unit") },
    )
    out = StringIO.new

    When "printing the node"
    printer.print_node(path: ["test"], command: test, out: out)

    Then "the bare form leads, the subcommand form follows"
    lines = out.string.lines.map(&:chomp)
    lines.fetch(0) == "Usage: dev test [args...]"
    lines.fetch(1) == "       dev test <command> [args...]"
    lines.fetch(3) == "Run every suite"
    lines.include?("  unit         Unit")
  end

  test "print_node renders a childless command as its one invocation and description" do
    Given "a leaf"
    printer = Dev::Cli::UsagePrinter.new
    out = StringIO.new

    When "printing the node"
    printer.print_node(path: ["test", "unit"], command: Dev::ProjectCommand.new(run: "rspec", desc: "Unit tests"), out: out)

    Then "no Commands section"
    out.string == "Usage: dev test unit [args...]\n\nUnit tests\n"
  end

  def build_group(path, desc: "a group", category: Dev::Command::Category::Project, children: nil)
    Dev::CommandGroup.new(
      path: path, desc: desc, category: category, children: children || { "child" => workflow_builtin },
    )
  end
end
