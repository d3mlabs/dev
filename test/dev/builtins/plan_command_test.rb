# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/plan_command"
require "pathname"

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

  test "call builds the accessor for the project in hand and dispatches argv" do
    Given "a factory that records its root and an expecting accessor"
    root = Pathname.new("/tmp/plan-test")
    accessor = typed_mock(Dev::Plan::Accessor)
    accessor.expects(:run).with(["status"]).once
    factory_roots = []
    command = Dev::Builtins::PlanCommand.new(
      accessor_factory: ->(project_root) {
        factory_roots << project_root
        accessor
      },
    )

    When "running plan"
    command.call(args: ["status"], context: build_context(root))

    Then "the accessor was scoped to the project root"
    factory_roots == [root]
  end

  private

  def build_context(project_root)
    Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui), ruby_version: "4.0.1", project_root: project_root)
  end
end
