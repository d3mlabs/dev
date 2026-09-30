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

  test "call with no path renders the root's usage through the printer" do
    Given "a printer expecting the provider's root at the empty path"
    root = build_root({ "test" => Dev::ProjectCommand.new(run: "rspec", desc: "Run tests") })
    out = StringIO.new
    usage_printer = typed_mock(Dev::Cli::UsagePrinter)
    usage_printer.expects(:print_node).with(path: [], command: root, out: out).once
    command = build_help(usage_printer: usage_printer, out: out, root_provider: -> { root })

    When "running help"
    command.call(args: [], context: build_context)

    Then "the printer expectation holds"
    true
  end

  test "the tree is consulted at call time, not construction time" do
    Given "a provider over a root assigned only after help is constructed"
    root = nil
    printed = []
    usage_printer = typed_mock(Dev::Cli::UsagePrinter)
    usage_printer.stubs(:print_node).with { |command:, **| printed << command }
    command = build_help(usage_printer: usage_printer, root_provider: -> { root })
    root = build_root({ "up" => Dev::ProjectCommand.new(run: "./bin/up.rb", desc: "Setup") })

    When "running help"
    command.call(args: [], context: build_context)

    Then "the late-assigned root is what renders"
    printed.fetch(0) == root
  end

  test "help <path> renders the usage of the node the path reaches" do
    Given "a two-level tree and a printer expecting the inner group at its path"
    inner = build_group(["test", "unit"], children: { "fast" => Dev::ProjectCommand.new(run: "rspec") })
    outer = build_group(["test"], children: { "unit" => inner })
    out = StringIO.new
    usage_printer = typed_mock(Dev::Cli::UsagePrinter)
    usage_printer.expects(:print_node).with(path: ["test", "unit"], command: inner, out: out).once
    command = build_help(usage_printer: usage_printer, out: out, root_provider: -> { build_root({ "test" => outer }) })

    When "asking for help on the nested path"
    command.call(args: ["test", "unit"], context: build_context)

    Then "the printer expectation holds"
    true
  end

  test "help <path> walks through a runnable command's children to a leaf" do
    Given "a leaf under a runnable project command"
    leaf = Dev::ProjectCommand.new(run: "rspec", desc: "Unit tests")
    test = Dev::ProjectCommand.new(run: "./bin/test.sh", children: { "unit" => leaf })
    out = StringIO.new
    usage_printer = typed_mock(Dev::Cli::UsagePrinter)
    usage_printer.expects(:print_node).with(path: ["test", "unit"], command: leaf, out: out).once
    command = build_help(usage_printer: usage_printer, out: out, root_provider: -> { build_root({ "test" => test }) })

    When "asking for help on the leaf"
    command.call(args: ["test", "unit"], context: build_context)

    Then "the printer expectation holds"
    true
  end

  test "help <path> on an unknown path raises UnknownCommandError naming the path" do
    Given "a tree without the asked name"
    command = build_help(root_provider: -> { build_root({ "up" => Dev::ProjectCommand.new(run: "x") }) })

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

  def build_root(children)
    Dev::CommandGroup.root(desc: "Development commands for testproject", children: children)
  end

  def build_help(usage_printer: typed_mock(Dev::Cli::UsagePrinter), out: StringIO.new,
    root_provider: -> { build_root({ "up" => Dev::ProjectCommand.new(run: "x") }) })
    Dev::Builtins::HelpCommand.new(usage_printer:, out:, root_provider:)
  end

  def build_context
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(name: "TestProject", root: Pathname.new("/tmp/help-test"), ruby_version: "4.0.1"),
    )
  end
end
