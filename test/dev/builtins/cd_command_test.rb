# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/cd_command"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::CdCommandTest < Minitest::Test
  include SorbetHelper

  test "call dispatches argv to the cd accessor" do
    Given "a cd command over an expecting accessor"
    accessor = typed_mock(Dev::Cd::Accessor)
    accessor.expects(:run).with(["widget"]).once
    command = Dev::Builtins::CdCommand.new(accessor: accessor)

    When "running cd"
    command.call(args: ["widget"], context: build_context)

    Then "the expectation on the accessor holds"
    true
  end

  private

  def build_context
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui), ruby_version: "4.0.1", project_root: Pathname.new("/tmp/cd-test"),
    )
  end
end
