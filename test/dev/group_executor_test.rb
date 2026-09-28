# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command"
require "dev/group_executor"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::GroupExecutorTest < Minitest::Test
  include SorbetHelper

  class FakeBuiltin < Dev::BuiltinCommand
    def desc = "a builtin"

    def category = Dev::Command::Category::Workflow

    def call(args:, context:); end
  end

  test "execute prints the group's usage to the injected stream" do
    Given "a printer expecting the group and the executor's stream"
    group = Dev::CommandGroup.new(
      path: ["deps"], desc: "Dependency lookups", category: Dev::Command::Category::Lifecycle,
      children: { "path" => FakeBuiltin.new },
    )
    out = StringIO.new
    usage_printer = typed_mock(Dev::Cli::UsagePrinter)
    usage_printer.expects(:print_group).with(group: group, out: out).once
    executor = Dev::GroupExecutor.new(usage_printer: usage_printer, out: out)

    When "executing the group"
    executor.execute(group)

    Then "the printer expectation holds"
    true
  end
end
