# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/cred_get_command"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::CredGetCommandTest < Minitest::Test
  include SorbetHelper

  test "traits: exempt from staleness (host-global), never stamps, workflow section" do
    Given "the builtin"
    command = Dev::Builtins::CredGetCommand.new(accessor: typed_mock(Dev::CredentialAccessor), out: StringIO.new)

    Expect "the declarative traits"
    command.staleness_exempt? == true
    command.stamps? == false
    command.category == Dev::Command::Category::Workflow
  end

  test "call forwards its argv and stream to the accessor's get" do
    Given "a cred get leaf over an expecting accessor"
    out = StringIO.new
    accessor = typed_mock(Dev::CredentialAccessor)
    accessor.expects(:get).with(["wwise", "email"], out: out).once
    command = Dev::Builtins::CredGetCommand.new(accessor: accessor, out: out)

    When "running cred get"
    command.call(args: ["wwise", "email"], context: Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui)))

    Then "the expectation on the accessor holds"
    true
  end
end
