# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/project_executor"
require "dev/cli/command"

# The strategy is a thin seam over the injected CommandRunner: each public
# message delegates to the runner's same-named message, and exec_into adds
# the never-returns honesty guard. The Kernel.exec / Kernel.system process
# shapes themselves are CommandRunner's contract (see command_runner_test).
transform!(RSpock::AST::Transformation)
class Dev::Cli::ProjectExecutorTest < Minitest::Test
  include SorbetHelper

  def build_command
    Dev::Cli::ProjectCommand.new(run: "./bin/test.sh", desc: "Run tests")
  end

  test "exec_into hands the command to the runner's exec message with exact args" do
    Given "an executor over a runner expecting the exec message"
    command = build_command
    command_runner = typed_mock(Dev::Cli::CommandRunner)
    executor = Dev::Cli::ProjectExecutor.new(command_runner: command_runner)

    When "exec_into runs (the mocked runner returns, so the honesty guard raises)"
    executor.exec_into(command, args: ["--fast", "spec/a"])

    Then "the runner got the exec message, never the waiting one"
    1 * command_runner.exec_into(command, args: ["--fast", "spec/a"])
    0 * command_runner.run_waiting
    raises Dev::Cli::ProjectExecutor::ExecReturnedError
  end

  test "a returning exec boundary raises ExecReturnedError" do
    Given "a runner whose exec message returns control instead of replacing the process"
    command_runner = typed_mock(Dev::Cli::CommandRunner)
    executor = Dev::Cli::ProjectExecutor.new(command_runner: command_runner)

    When "exec_into runs"
    executor.exec_into(build_command, args: [])

    Then "the never-returns contract raises"
    _ * command_runner.exec_into
    raises Dev::Cli::ProjectExecutor::ExecReturnedError
  end

  test "run_waiting hands the command to the runner's waiting message and returns control" do
    Given "an executor over a runner expecting the waiting message"
    command = build_command
    command_runner = typed_mock(Dev::Cli::CommandRunner)
    executor = Dev::Cli::ProjectExecutor.new(command_runner: command_runner)

    When "run_waiting runs"
    executor.run_waiting(command, args: ["-v"])

    Then "the runner got the waiting message, never the exec one, and control returned"
    1 * command_runner.run_waiting(command, args: ["-v"])
    0 * command_runner.exec_into
  end
end
