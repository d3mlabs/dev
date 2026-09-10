# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/cred_command"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::CredCommandTest < Minitest::Test
  include SorbetHelper

  test "call dispatches argv to the credential accessor" do
    Given "a cred command over an expecting accessor"
    accessor = typed_mock(Dev::CredentialAccessor)
    accessor.expects(:run).with(["get", "wwise", "email"]).once
    command = Dev::Builtins::CredCommand.new(accessor: accessor)

    When "running cred"
    command.call(args: ["get", "wwise", "email"], context: build_context)

    Then "the expectation on the accessor holds"
    true
  end

  private

  def build_context
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(root: Pathname.new("/tmp/cred-test"), ruby_version: "4.0.1"),
    )
  end
end
