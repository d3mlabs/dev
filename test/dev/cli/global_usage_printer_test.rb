# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/global_usage_printer"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Cli::GlobalUsagePrinterTest < Minitest::Test
  # A builtin with a declared description; global listing tests need
  # nothing more of it.
  class FakeBuiltin < Dev::BuiltinCommand
    def initialize(desc:, hidden: false)
      super()
      @desc = desc
      @hidden = hidden
    end

    attr_reader :desc

    def hidden? = @hidden
    def category = Dev::Command::Category::Workflow
    def call(args:, context:); end
  end

  test "print renders the usage line, each global command, and the project hint" do
    Given "a small global tree with a leaf and a group"
    printer = Dev::Cli::GlobalUsagePrinter.new
    commands = {
      "cd" => FakeBuiltin.new(desc: "Jump to a checkout"),
      "plan" => Dev::CommandGroup.new(
        path: ["plan"], desc: "Sync plans", category: Dev::Command::Category::Workflow,
        children: { "status" => FakeBuiltin.new(desc: "Sync state") },
      ),
    }
    out = StringIO.new

    When "printing the global usage"
    printer.print(commands: commands, out: out)

    Then "the header, rows (groups with the tree marker), and hint all render"
    out.string.include?("Usage: dev <command> [args...]")
    out.string.include?("Global commands (available anywhere):")
    out.string.include?("  cd           Jump to a checkout")
    out.string.include?("  plan …       Sync plans")
    out.string.include?("Run dev inside a project that defines a dev.yml to see its commands.")
  end

  test "commands list alphabetically regardless of registration order; hidden ones are omitted" do
    Given "a catalog registered out of alphabetical order with one hidden entry"
    printer = Dev::Cli::GlobalUsagePrinter.new
    commands = {
      "plan" => FakeBuiltin.new(desc: "Sync plans"),
      "cd" => FakeBuiltin.new(desc: "Jump to a checkout"),
      "complete" => FakeBuiltin.new(desc: "plumbing", hidden: true),
      "learnings" => FakeBuiltin.new(desc: "Learnings read path"),
    }
    out = StringIO.new

    When "printing the global usage"
    printer.print(commands: commands, out: out)

    Then "rows appear alphabetically and the hidden one is absent"
    lines = out.string.lines.map(&:chomp)
    lines.index("  cd           Jump to a checkout") <
      lines.index("  learnings    Learnings read path")
    lines.index("  learnings    Learnings read path") <
      lines.index("  plan         Sync plans")
    !out.string.include?("plumbing")
  end
end
