# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/project_executor"
require "dev/command"

# The strategy is a thin seam over the injected CommandRunner: each public
# message delegates to the runner's same-named message, and exec_into adds
# the never-returns honesty guard. The Kernel.exec / Kernel.system process
# shapes themselves are CommandRunner's contract (see command_runner_test).
transform!(RSpock::AST::Transformation)
class Dev::ProjectExecutorTest < Minitest::Test
  include SorbetHelper

  def build_command
    Dev::ProjectCommand.new(run: "./bin/test.sh", desc: "Run tests", container: false)
  end

  test "exec_into hands the command to the runner's exec message with exact args" do
    Given "an executor over a runner expecting the exec message"
    command = build_command
    command_runner = typed_mock(Dev::CommandRunner)
    command_runner.expects(:exec_into).with(command, args: ["--fast", "spec/a"]).once
    command_runner.expects(:run_waiting).never
    executor = Dev::ProjectExecutor.new(command_runner: command_runner)

    When "exec_into runs (the mocked runner returns, so the honesty guard raises)"
    error = nil
    begin
      executor.exec_into(command, args: ["--fast", "spec/a"])
    rescue Dev::ProjectExecutor::ExecReturnedError => e
      error = e
    end

    Then "the runner got the exec message, never the waiting one"
    !error.nil?
  end

  test "a returning exec boundary raises ExecReturnedError" do
    Given "a runner whose exec message returns control instead of replacing the process"
    command_runner = typed_mock(Dev::CommandRunner)
    command_runner.stubs(:exec_into)
    executor = Dev::ProjectExecutor.new(command_runner: command_runner)

    When "exec_into runs"
    executor.exec_into(build_command, args: [])

    Then "the never-returns contract raises"
    raises Dev::ProjectExecutor::ExecReturnedError
  end

  test "run_waiting hands the command to the runner's waiting message and returns control" do
    Given "an executor over a runner expecting the waiting message"
    command = build_command
    command_runner = typed_mock(Dev::CommandRunner)
    command_runner.expects(:run_waiting).with(command, args: ["-v"]).once
    command_runner.expects(:exec_into).never
    executor = Dev::ProjectExecutor.new(command_runner: command_runner)

    When "run_waiting runs"
    executor.run_waiting(command, args: ["-v"])

    Then "control returned for the caller's post-execute steps"
    true
  end
end
