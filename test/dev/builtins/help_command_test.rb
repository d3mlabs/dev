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

  private

  def build_help(project_name: "testproject", usage_printer: typed_mock(Dev::Cli::UsagePrinter),
    out: StringIO.new, commands_provider: -> { {} })
    Dev::Builtins::HelpCommand.new(project_name:, usage_printer:, out:, commands_provider:)
  end

  def build_context
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui), ruby_version: "4.0.1", project_root: Pathname.new("/tmp/help-test"),
    )
  end
end
