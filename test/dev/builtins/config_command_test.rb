# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/config_command"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::ConfigCommandTest < Minitest::Test
  include SorbetHelper

  test "call dispatches argv to the config accessor" do
    Given "a config command over an expecting accessor"
    accessor = typed_mock(Dev::ConfigAccessor)
    accessor.expects(:run).with(["get", "plans_repo"]).once
    command = Dev::Builtins::ConfigCommand.new(accessor: accessor)

    When "running config"
    command.call(args: ["get", "plans_repo"], context: build_context)

    Then "the expectation on the accessor holds"
    true
  end

  private

  def build_context
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui), ruby_version: "4.0.1", project_root: Pathname.new("/tmp/config-test"),
    )
  end
end
