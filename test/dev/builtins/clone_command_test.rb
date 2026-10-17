# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/clone_command"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::CloneCommandTest < Minitest::Test
  include SorbetHelper

  test "#{words.inspect} dispatches the target to the accessor, plumbing: #{plumbing}" do
    Given "a clone command over an expecting accessor"
    accessor = typed_mock(Dev::Clone::Accessor)
    accessor.expects(:run).with("acme/widget", plumbing: plumbing, out: $stdout, err: $stderr).once
    command = Dev::Builtins::CloneCommand.new(accessor: accessor)

    When "running clone"
    command.call(args: parsed_args(command, words), context: build_context)

    Then "the expectation on the accessor holds"
    true

    Where
    words                     | plumbing
    ["acme/widget"]           | false
    ["--path", "acme/widget"] | true
  end

  test "#{words.inspect} is a usage error: #{reason}" do
    Given "a clone command over a strict accessor"
    command = Dev::Builtins::CloneCommand.new(accessor: typed_mock(Dev::Clone::Accessor))

    When "running clone"
    command.call(args: parsed_args(command, words), context: build_context)

    Then
    raises Dev::Clone::Accessor::UsageError

    Where
    words                | reason
    []                   | "no target"
    ["a", "b"]           | "two targets"
    ["--path"]           | "plumbing with no target"
    ["--path", "a", "b"] | "plumbing with two targets"
  end

  private

  def build_context
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(name: "TestProject", root: Pathname.new("/tmp/clone-test"), ruby_version: "4.0.1"),
    )
  end
end
