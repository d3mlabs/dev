# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/clone_command"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::CloneCommandTest < Minitest::Test
  include SorbetHelper

  test "call dispatches argv to the clone accessor" do
    Given "a clone command over an expecting accessor"
    accessor = typed_mock(Dev::Clone::Accessor)
    accessor.expects(:run).with(["acme/widget"]).once
    command = Dev::Builtins::CloneCommand.new(accessor: accessor)

    When "running clone"
    command.call(args: ["acme/widget"], context: build_context)

    Then "the expectation on the accessor holds"
    true
  end

  private

  def build_context
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui), ruby_version: "4.0.1", project_root: Pathname.new("/tmp/clone-test"),
    )
  end
end
