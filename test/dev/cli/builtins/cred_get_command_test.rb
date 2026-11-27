# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/builtins/cred_get_command"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Cli::Builtins::CredGetCommandTest < Minitest::Test
  include SorbetHelper

  test "traits: exempt from staleness (host-global), never stamps, workflow section" do
    Given "the builtin"
    command = Dev::Cli::Builtins::CredGetCommand.new(accessor: typed_mock(Dev::CredentialAccessor), out: StringIO.new)

    Expect "the declarative traits"
    command.staleness_exempt? == true
    command.stamps? == false
    command.category == Dev::Cli::Command::Category::Workflow
    command.desc == "Print a stored credential, resolved through the provider chain"
    command.positionals.map(&:usage) == ["<namespace>", "<key>"]
  end

  test "call forwards its argv, the context's Ui and its stream to the accessor's get" do
    Given "a cred get leaf over an expecting accessor"
    out = StringIO.new
    ui = typed_mock(Dev::Ui)
    accessor = typed_mock(Dev::CredentialAccessor)
    command = Dev::Cli::Builtins::CredGetCommand.new(accessor: accessor, out: out)

    When "running cred get"
    command.call(args: parsed_args(command, ["wwise", "email"]), context: Dev::Cli::ExecutionContext.new(ui: ui))

    Then "the accessor gets the credential"
    1 * accessor.get(["wwise", "email"], ui: ui, out: out)
  end
end
