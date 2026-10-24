# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/cd_command"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::CdCommandTest < Minitest::Test
  include SorbetHelper

  test "#{words.inspect} dispatches to #{verb} with #{expected.inspect}" do
    Given "a cd command over an expecting accessor"
    accessor = typed_mock(Dev::Cd::Accessor)
    accessor.expects(verb).with(*expected).once
    command = Dev::Builtins::CdCommand.new(accessor: accessor)

    When "running cd"
    command.call(args: parsed_args(command, words), context: build_context)

    Then "the expectation on the accessor holds"
    true

    Where
    words                       | verb                  | expected
    ["--resolve", "widget"]     | :resolve              | ["widget", { out: $stdout, err: $stderr }]
    ["--candidates", "wid"]     | :candidates           | ["wid", { out: $stdout }]
    ["--candidates"]            | :candidates           | ["", { out: $stdout }]
    ["widget"]                  | :explain_missing_hook | [{ err: $stderr }]
    []                          | :explain_missing_hook | [{ err: $stderr }]
  end

  test "#{words.inspect} is a usage error: #{reason}" do
    Given "a cd command over a strict accessor"
    command = Dev::Builtins::CdCommand.new(accessor: typed_mock(Dev::Cd::Accessor))

    When "running cd"
    command.call(args: parsed_args(command, words), context: build_context)

    Then
    raises Dev::Cd::Accessor::UsageError

    Where
    words                            | reason
    ["--resolve"]                    | "resolve needs a query"
    ["--resolve", "a", "b"]          | "resolve takes one query"
    ["--candidates", "a", "b"]       | "candidates take at most one query"
  end

  private

  def build_context
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(name: "TestProject", root: Pathname.new("/tmp/cd-test")),
    )
  end
end
