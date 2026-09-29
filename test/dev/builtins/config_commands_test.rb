# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/config_get_command"
require "dev/builtins/config_list_command"
require "dev/builtins/config_set_command"
require "stringio"

# The three `config` verbs share one shape (accessor + out, one verb call),
# so one Where-driven file covers them: each row is a leaf class, the
# accessor verb it forwards to, and the argv it forwards.
transform!(RSpock::AST::Transformation)
class Dev::Builtins::ConfigCommandsTest < Minitest::Test
  include SorbetHelper

  test "#{klass} traits: exempt from staleness (host-global), never stamps, workflow section" do
    Given "the builtin"
    command = klass.new(accessor: typed_mock(Dev::ConfigAccessor), out: StringIO.new)

    Expect "the declarative traits"
    command.staleness_exempt? == true
    command.stamps? == false
    command.category == Dev::Command::Category::Workflow
    command.hidden? == false
    !command.desc.empty?

    Where
    klass                               | _
    Dev::Builtins::ConfigListCommand    | 0
    Dev::Builtins::ConfigGetCommand     | 0
    Dev::Builtins::ConfigSetCommand     | 0
  end

  test "#{klass} forwards its argv to the accessor's #{verb}" do
    Given "an accessor expecting the verb and the injected stream"
    out = StringIO.new
    accessor = typed_mock(Dev::ConfigAccessor)
    expectation = accessor.expects(verb).once
    expectation.with(*expected_args, out: out)
    command = klass.new(accessor: accessor, out: out)

    When "calling the leaf"
    command.call(args: args, context: build_context)

    Then "the verb was called"
    true

    Where
    klass                            | verb  | args                     | expected_args
    Dev::Builtins::ConfigListCommand | :list | []                       | []
    Dev::Builtins::ConfigGetCommand  | :get  | ["plans_repo"]           | [["plans_repo"]]
    Dev::Builtins::ConfigSetCommand  | :set  | ["plans_repo", "a/b"]    | [["plans_repo", "a/b"]]
  end

  test "config list rejects trailing arguments with the accessor's usage" do
    Given "the list leaf"
    command = Dev::Builtins::ConfigListCommand.new(accessor: typed_mock(Dev::ConfigAccessor), out: StringIO.new)

    When "calling it with an argument"
    command.call(args: ["extra"], context: build_context)

    Then
    raises Dev::ConfigAccessor::UsageError
  end

  private

  def build_context
    Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui))
  end
end
