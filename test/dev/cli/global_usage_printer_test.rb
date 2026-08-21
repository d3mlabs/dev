# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/global_usage_printer"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Cli::GlobalUsagePrinterTest < Minitest::Test
  test "print renders the usage line, each global command, and the project hint" do
    Given "a name-to-description catalog"
    printer = Dev::Cli::GlobalUsagePrinter.new
    commands = {
      "cd" => "Jump to a checkout",
      "plan" => "Sync plans",
    }
    out = StringIO.new

    When "printing the global usage"
    printer.print(commands: commands, out: out)

    Then "the header, rows, and hint all render"
    out.string.include?("Usage: dev <command> [args...]")
    out.string.include?("Global commands (available anywhere):")
    out.string.include?("  cd           Jump to a checkout")
    out.string.include?("  plan         Sync plans")
    out.string.include?("Run dev inside a project that defines a dev.yml to see its commands.")
  end

  test "commands list alphabetically regardless of registration order" do
    Given "a catalog registered out of alphabetical order"
    printer = Dev::Cli::GlobalUsagePrinter.new
    commands = {
      "plan" => "Sync plans",
      "cd" => "Jump to a checkout",
      "learnings" => "Learnings read path",
    }
    out = StringIO.new

    When "printing the global usage"
    printer.print(commands: commands, out: out)

    Then "rows appear alphabetically"
    lines = out.string.lines.map(&:chomp)
    lines.index("  cd           Jump to a checkout") <
      lines.index("  learnings    Learnings read path")
    lines.index("  learnings    Learnings read path") <
      lines.index("  plan         Sync plans")
  end
end
