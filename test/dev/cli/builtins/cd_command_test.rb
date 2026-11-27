# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/builtins/cd_command"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Cli::Builtins::CdCommandTest < Minitest::Test
  include SorbetHelper

  test "--resolve <query> dispatches to resolve with the query and both streams" do
    Given "a cd command over an expecting accessor"
    accessor = typed_mock(Dev::Cd::Accessor)
    command = Dev::Cli::Builtins::CdCommand.new(accessor: accessor)

    When "running cd"
    command.call(args: parsed_args(command, ["--resolve", "widget"]), context: build_context)

    Then "the accessor resolves the query"
    1 * accessor.resolve("widget", out: $stdout, err: $stderr)
  end

  test "#{words.inspect} dispatches to candidates with #{query.inspect}" do
    Given "a cd command over an expecting accessor"
    accessor = typed_mock(Dev::Cd::Accessor)
    command = Dev::Cli::Builtins::CdCommand.new(accessor: accessor)

    When "running cd"
    command.call(args: parsed_args(command, words), context: build_context)

    Then "the accessor lists candidates for the query"
    1 * accessor.candidates(query, out: $stdout)

    Where
    words                   | query
    ["--candidates", "wid"] | "wid"
    ["--candidates"]        | ""
  end

  test "#{words.inspect} dispatches to explain_missing_hook" do
    Given "a cd command over an expecting accessor"
    accessor = typed_mock(Dev::Cd::Accessor)
    command = Dev::Cli::Builtins::CdCommand.new(accessor: accessor)

    When "running cd"
    command.call(args: parsed_args(command, words), context: build_context)

    Then "the accessor explains the missing shell hook"
    1 * accessor.explain_missing_hook(err: $stderr)

    Where
    words
    ["widget"]
    []
  end

  test "#{words.inspect} is a usage error: #{reason}" do
    Given "a cd command over a strict accessor"
    command = Dev::Cli::Builtins::CdCommand.new(accessor: typed_mock(Dev::Cd::Accessor))

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
    Dev::Cli::ExecutionContext.new(
      ui: typed_mock(Dev::Ui),
      project: Dev::Cli::ProjectContext.new(name: "TestProject", root: Pathname.new("/tmp/cd-test")),
    )
  end
end
