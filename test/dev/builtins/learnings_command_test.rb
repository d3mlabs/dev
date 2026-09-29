# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/learnings_command"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::LearningsCommandTest < Minitest::Test
  include SorbetHelper

  test "traits: never nags (headless hook contexts), never stamps" do
    Given "the builtin"
    command = Dev::Builtins::LearningsCommand.new

    Expect "the declarative traits"
    command.staleness_exempt? == false
    command.stamps? == false
  end

  test "call builds the accessor per call (no project needed) and dispatches argv" do
    Given "a counting factory and an expecting accessor"
    accessor = typed_mock(Dev::Learnings::Accessor)
    accessor.expects(:run).with(["status"]).once
    calls = 0
    command = Dev::Builtins::LearningsCommand.new(accessor_factory: lambda {
      calls += 1
      accessor
    })

    When "running learnings in a projectless context"
    command.call(args: ["status"], context: Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui)))

    Then "the factory was consulted once"
    calls == 1
  end
end
