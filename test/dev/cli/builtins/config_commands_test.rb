# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/builtins/config_get_command"
require "dev/cli/builtins/config_list_command"
require "dev/cli/builtins/config_set_command"
require "stringio"

# The three `config` verbs share one shape (accessor + out, one verb call),
# so one file covers them: the traits are Where-driven over the leaf classes,
# and each leaf gets one forwarding test naming the accessor verb it calls.
transform!(RSpock::AST::Transformation)
class Dev::Cli::Builtins::ConfigCommandsTest < Minitest::Test
  include SorbetHelper

  test "#{klass} traits: exempt from staleness (host-global), never stamps, workflow section" do
    Given "the builtin"
    command = klass.new(accessor: typed_mock(Dev::ConfigAccessor), out: StringIO.new)

    Expect "the declarative traits"
    command.staleness_exempt? == true
    command.stamps? == false
    command.category == Dev::Cli::Command::Category::Workflow
    command.hidden? == false
    !command.desc.empty?

    Where
    klass                                 | _
    Dev::Cli::Builtins::ConfigListCommand | 0
    Dev::Cli::Builtins::ConfigGetCommand  | 0
    Dev::Cli::Builtins::ConfigSetCommand  | 0
  end

  test "config list forwards the injected stream to the accessor's list" do
    Given "an accessor behind the list leaf"
    out = StringIO.new
    accessor = typed_mock(Dev::ConfigAccessor)
    command = Dev::Cli::Builtins::ConfigListCommand.new(accessor: accessor, out: out)

    When "calling the leaf"
    command.call(args: parsed_args(command, []), context: build_context)

    Then "the verb was called"
    1 * accessor.list(out: out)
  end

  test "config get forwards its argv to the accessor's get" do
    Given "an accessor behind the get leaf"
    out = StringIO.new
    accessor = typed_mock(Dev::ConfigAccessor)
    command = Dev::Cli::Builtins::ConfigGetCommand.new(accessor: accessor, out: out)

    When "calling the leaf"
    command.call(args: parsed_args(command, ["plans_repo"]), context: build_context)

    Then "the verb was called"
    1 * accessor.get(["plans_repo"], out: out)
  end

  test "config set forwards its argv to the accessor's set" do
    Given "an accessor behind the set leaf"
    out = StringIO.new
    accessor = typed_mock(Dev::ConfigAccessor)
    command = Dev::Cli::Builtins::ConfigSetCommand.new(accessor: accessor, out: out)

    When "calling the leaf"
    command.call(args: parsed_args(command, ["plans_repo", "a/b"]), context: build_context)

    Then "the verb was called"
    1 * accessor.set(["plans_repo", "a/b"], out: out)
  end

  test "config list rejects trailing arguments with the accessor's usage" do
    Given "the list leaf"
    command = Dev::Cli::Builtins::ConfigListCommand.new(accessor: typed_mock(Dev::ConfigAccessor), out: StringIO.new)

    When "calling it with an argument"
    command.call(args: parsed_args(command, ["extra"]), context: build_context)

    Then
    raises Dev::ConfigAccessor::UsageError
  end

  private

  def build_context
    Dev::Cli::ExecutionContext.new(ui: typed_mock(Dev::Ui))
  end
end
