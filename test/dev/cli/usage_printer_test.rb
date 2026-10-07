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

  # Print the root over the given children the way bare `dev` does.
  def print_root(children, epilogue: "Examples: dev up    dev test", desc: "Development commands for myproject")
    out = StringIO.new
    Dev::Cli::UsagePrinter.new(epilogue: epilogue).print_node(
      path: [], command: Dev::CommandGroup.root(desc: desc, children: children), out: out,
    )
    out.string
  end

  test "the root renders the three sections in fixed order when its children span categories" do
    Given "one command per category"
    children = {
      "up" => lifecycle_builtin(desc: "Provision"),
      "help" => workflow_builtin(desc: "Show this usage"),
      "test" => Dev::ProjectCommand.new(run: "rspec", desc: "Run tests"),
    }

    When "printing the root"
    output = print_root(children)

    Then "the invocation and desc lead; each command renders under its section, sections in fixed order"
    lines = output.lines.map(&:chomp)
    lines.fetch(0) == "Usage: dev <command> [args...]"
    lines.fetch(2) == "Development commands for myproject"
    lines.index("Project commands:") < lines.index("  test         Run tests")
    lines.index("Lifecycle:") < lines.index("  up           Provision")
    lines.index("Development flow:") < lines.index("  help         Show this usage")
    lines.index("Project commands:") < lines.index("Lifecycle:")
    lines.index("Lifecycle:") < lines.index("Development flow:")
    !lines.include?("Commands:")
  end

  test "the root closes with the epilogue; other nodes do not" do
    Given "a printer with an epilogue and a group under the root"
    printer = Dev::Cli::UsagePrinter.new(epilogue: "Examples: dev up")
    group = build_group(["deps"])
    root_out = StringIO.new
    group_out = StringIO.new

    When "printing both"
    printer.print_node(path: [], command: Dev::CommandGroup.root(desc: "d", children: { "deps" => group }), out: root_out)
    printer.print_node(path: ["deps"], command: group, out: group_out)

    Then "the epilogue is the root's last line, absent from the group's usage"
    root_out.string.lines.last == "Examples: dev up\n"
    !group_out.string.include?("Examples")
  end

  test "a root printed without an epilogue ends at its listing" do
    Given "no epilogue"
    output = print_root({ "up" => lifecycle_builtin }, epilogue: nil)

    Expect
    output.lines.last == "  up           a lifecycle builtin\n"
  end

  test "commands list alphabetically within a section" do
    Given "lifecycle commands registered out of alphabetical order"
    children = {
      "update-deps" => lifecycle_builtin,
      "check" => lifecycle_builtin,
      "install-deps" => lifecycle_builtin,
    }

    When "printing the root"
    lines = print_root(children).lines.map(&:chomp)

    Then "the section lists them alphabetically"
    lines.index("  check        a lifecycle builtin") <
      lines.index("  install-deps a lifecycle builtin")
    lines.index("  install-deps a lifecycle builtin") <
      lines.index("  update-deps  a lifecycle builtin")
  end

  test "children of one category list under a plain Commands heading, whatever the category" do
    Given "roots whose children share a category"
    project_only = print_root({ "test" => Dev::ProjectCommand.new(run: "rspec", desc: "Run tests") })
    lifecycle_only = print_root({ "up" => lifecycle_builtin })

    Expect "no section headings"
    project_only.include?("\nCommands:\n  test         Run tests\n")
    !project_only.include?("Project commands:")
    lifecycle_only.include?("\nCommands:\n")
    !lifecycle_only.include?("Lifecycle:")
  end

  test "sections without commands are omitted" do
    Given "children spanning two of the three categories"
    output = print_root({ "test" => Dev::ProjectCommand.new(run: "rspec", desc: "Run tests"), "help" => workflow_builtin })

    Expect "no empty section header renders"
    output.include?("Project commands:")
    output.include?("Development flow:")
    !output.include?("Lifecycle:")
  end

  test "an overridden slot lists under the builtin's section with the project's desc" do
    Given "a lifecycle slot overridden by a project command, beside a project command"
    overridden = Dev::OverriddenCommand.new(
      builtin: lifecycle_builtin(desc: "builtin up"),
      project: Dev::ProjectCommand.new(run: "./bin/up.rb", desc: "Project setup"),
    )

    When "printing the root"
    output = print_root({ "up" => overridden, "test" => Dev::ProjectCommand.new(run: "rspec", desc: "Run tests") })

    Then "the slot renders under Lifecycle with the override's description"
    lines = output.lines.map(&:chomp)
    lines.index("Lifecycle:") < lines.index("  up           Project setup")
    !output.include?("builtin up")
  end

  test "nodes with children list with a trailing ellipsis, groups and runnable commands alike" do
    Given "a group and a runnable command heading a child"
    group = build_group(["deps"], category: Dev::Command::Category::Lifecycle, desc: "Dependency lookups")
    test = Dev::ProjectCommand.new(run: "./bin/test.sh", desc: "All tests", children: { "unit" => workflow_builtin })

    When "printing the root"
    output = print_root({ "deps" => group, "test" => test })

    Then "the marker tells the reader there is more beneath"
    output.include?("  deps …       Dependency lookups")
    output.include?("  test …       All tests")
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
        "check" => build_group(["deps", "check"], desc: "Checks", category: Dev::Command::Category::Lifecycle),
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

  test "a multi-line desc lists by its first line and prints in full on the node's own usage" do
    Given "a group whose desc carries a summary line and a detail line"
    printer = Dev::Cli::UsagePrinter.new
    group = build_group(["learnings"], desc: "The read path\nCapture is agent-driven.", category: Dev::Command::Category::Workflow)
    root_out = StringIO.new
    group_out = StringIO.new

    When "printing the root listing and the group's own usage"
    printer.print_node(path: [], command: Dev::CommandGroup.root(desc: "d", children: { "learnings" => group }), out: root_out)
    printer.print_node(path: ["learnings"], command: group, out: group_out)

    Then "the listing shows only the summary; the group's usage shows both lines"
    root_out.string.include?("  learnings …  The read path\n")
    !root_out.string.include?("Capture is agent-driven.")
    group_out.string.lines.map(&:chomp).fetch(2) == "The read path"
    group_out.string.lines.map(&:chomp).fetch(3) == "Capture is agent-driven."
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
