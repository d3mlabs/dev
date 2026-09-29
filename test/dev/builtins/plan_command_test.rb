# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/plan_command"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::PlanCommandTest < Minitest::Test
  include SorbetHelper

  test "traits: staleness-exempt (headless Cursor hooks), never stamps" do
    Given "the builtin"
    command = Dev::Builtins::PlanCommand.new

    Expect "the declarative traits"
    command.staleness_exempt? == true
    command.stamps? == false
  end

  test "call builds the accessor per call (no project needed) and dispatches argv" do
    Given "a counting factory and an expecting accessor"
    accessor = typed_mock(Dev::Plan::Accessor)
    accessor.expects(:run).with(["status"]).once
    calls = 0
    command = Dev::Builtins::PlanCommand.new(accessor_factory: lambda {
      calls += 1
      accessor
    })

    When "running plan in a projectless context"
    command.call(args: ["status"], context: Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui)))

    Then "the factory was consulted once"
    calls == 1
  end
end
