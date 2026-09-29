# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/plan_hook_after_edit_command"
require "dev/builtins/plan_init_command"
require "dev/builtins/plan_link_command"
require "dev/builtins/plan_new_command"
require "dev/builtins/plan_pull_command"
require "dev/builtins/plan_push_command"
require "dev/builtins/plan_status_command"
require "stringio"

# The `plan` verbs share PlanVerbCommand's shape (per-call accessor, host
# refresh first, then the verb), so one Where-driven file covers them: each
# row is a leaf, the accessor verb it forwards to, and the argv shape.
transform!(RSpock::AST::Transformation)
class Dev::Builtins::PlanCommandsTest < Minitest::Test
  include SorbetHelper

  LEAVES = {
    new: Dev::Builtins::PlanNewCommand,
    link: Dev::Builtins::PlanLinkCommand,
    pull: Dev::Builtins::PlanPullCommand,
    push: Dev::Builtins::PlanPushCommand,
    status: Dev::Builtins::PlanStatusCommand,
    init: Dev::Builtins::PlanInitCommand,
    hook: Dev::Builtins::PlanHookAfterEditCommand,
  }.freeze

  test "#{klass} traits: staleness-exempt (headless Cursor hooks), never stamps, workflow, hidden: #{hidden}" do
    Given "the builtin"
    command = klass.new(accessor_factory: -> { typed_mock(Dev::Plan::Accessor) }, out: StringIO.new)

    Expect "the declarative traits"
    command.staleness_exempt? == true
    command.stamps? == false
    command.category == Dev::Command::Category::Workflow
    command.hidden? == hidden
    !command.desc.empty?

    Where
    klass          | hidden
    LEAVES[:new]   | false
    LEAVES[:link]  | false
    LEAVES[:pull]  | false
    LEAVES[:push]  | false
    LEAVES[:status] | false
    LEAVES[:init]  | false
    LEAVES[:hook]  | true
  end

  test "#{klass} refreshes the host, then forwards #{args.inspect} to #{verb}" do
    Given "an accessor expecting the refresh then the verb, behind a counting factory"
    out = StringIO.new
    accessor = typed_mock(Dev::Plan::Accessor)
    sequence = sequence("plan verb")
    accessor.expects(:refresh_host).once.in_sequence(sequence)
    accessor.expects(verb).with(*expected_args, out: out).once.in_sequence(sequence)
    calls = 0
    command = klass.new(accessor_factory: lambda {
      calls += 1
      accessor
    }, out: out)

    When "calling the leaf in a projectless context"
    command.call(args: args, context: build_context)

    Then "the factory was consulted once"
    calls == 1

    Where
    klass           | verb      | args                    | expected_args
    LEAVES[:new]    | :new_plan | ["A title", "--blank"]  | [["A title", "--blank"]]
    LEAVES[:link]   | :link     | ["12", "x.plan.md"]     | [["12", "x.plan.md"]]
    LEAVES[:pull]   | :pull     | ["12", "--merge"]       | [["12", "--merge"]]
    LEAVES[:push]   | :push     | ["--org"]               | [["--org"]]
    LEAVES[:status] | :status   | []                      | []
    LEAVES[:init]   | :init     | []                      | [[]]
  end

  test "hook-after-edit refreshes the host, then hands the injected stdin payload to the accessor" do
    Given "a hook leaf over an expecting accessor and a payload stream"
    out = StringIO.new
    input = StringIO.new('{"file_path":"x"}')
    accessor = typed_mock(Dev::Plan::Accessor)
    sequence = sequence("hook")
    accessor.expects(:refresh_host).once.in_sequence(sequence)
    accessor.expects(:hook_after_edit).with(input, out: out).once.in_sequence(sequence)
    command = LEAVES[:hook].new(accessor_factory: -> { accessor }, out: out, input: input)

    When "the hook fires"
    command.call(args: [], context: build_context)

    Then "the expectations hold"
    true
  end

  test "#{klass} rejects stray arguments with the accessor's usage error" do
    Given "a leaf over an accessor that only expects the host refresh"
    accessor = typed_mock(Dev::Plan::Accessor)
    accessor.expects(:refresh_host).once
    command = klass.new(accessor_factory: -> { accessor }, out: StringIO.new)

    When "calling it with an argument it takes none of"
    command.call(args: ["extra"], context: build_context)

    Then
    raises Dev::Plan::Accessor::UsageError

    Where
    klass           | _
    LEAVES[:status] | 0
    LEAVES[:hook]   | 0
  end

  private

  def build_context
    Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui))
  end
end
