# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command_executor"
require "dev/command"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::CommandExecutorTest < Minitest::Test
  include SorbetHelper

  # Minimal builtin fake: the composite only dispatches on the variant's
  # type, so the fake carries no behavior — the strategy mock receives it
  # untouched.
  class FakeBuiltin < Dev::BuiltinCommand
    def desc = "a builtin"

    def category = Dev::Command::Category::Workflow

    def call(args:, context:); end
  end

  def build_context
    ui = typed_mock(Dev::Cli::Ui)
    Dev::ExecutionContext.new(
      ui: ui,
      project: Dev::ProjectContext.new(root: Pathname.new("/tmp/executor-test"), ruby_version: "4.0.1"),
    )
  end

  # Strategy mocks are strict: any message a test doesn't expect is an
  # unexpected invocation, so each arm proves the other two stayed silent.
  def build_strategies
    {
      builtin_executor: typed_mock(Dev::BuiltinExecutor),
      project_executor: typed_mock(Dev::ProjectExecutor),
      overridden_executor: typed_mock(Dev::OverriddenExecutor),
    }
  end

  test "a builtin command dispatches to the builtin strategy with exact args" do
    Given "a composite whose builtin strategy expects the dispatch"
    command = FakeBuiltin.new
    context = build_context
    strategies = build_strategies
    strategies.fetch(:builtin_executor)
      .expects(:execute).with(command, args: ["--verbose"], context: context).once
    executor = Dev::CommandExecutor.new(**strategies)

    When "executing"
    executor.execute(command, args: ["--verbose"], context: context)

    Then "the expectation held and no other strategy was consulted"
    true
  end

  test "a project command dispatches to the project strategy's exec tail-call" do
    Given "a composite whose project strategy expects exec_into"
    command = Dev::ProjectCommand.new(run: "./bin/test.sh", desc: "Run tests", container: false)
    context = build_context
    strategies = build_strategies
    strategies.fetch(:project_executor)
      .expects(:exec_into).with(command, args: ["--fast", "spec/a"]).once
    executor = Dev::CommandExecutor.new(**strategies)

    When "executing"
    executor.execute(command, args: ["--fast", "spec/a"], context: context)

    Then "the expectation held and no other strategy was consulted"
    true
  end

  test "a project command against a builtin-only composite is a wiring bug" do
    Given "a composite wired without project arms (the projectless wiring)"
    command = Dev::ProjectCommand.new(run: "./bin/test.sh", desc: "Run tests", container: false)
    executor = Dev::CommandExecutor.new(builtin_executor: typed_mock(Dev::BuiltinExecutor))

    When "executing"
    executor.execute(command, args: [], context: build_context)

    Then
    raises Dev::CommandExecutor::ProjectExecutionUnavailableError
  end

  test "an overridden command against a builtin-only composite is a wiring bug" do
    Given "a composite wired without project arms (the projectless wiring)"
    command = Dev::OverriddenCommand.new(
      builtin: FakeBuiltin.new,
      project: Dev::ProjectCommand.new(run: "./bin/up.rb", desc: "Setup", container: false),
    )
    executor = Dev::CommandExecutor.new(builtin_executor: typed_mock(Dev::BuiltinExecutor))

    When "executing"
    executor.execute(command, args: [], context: build_context)

    Then
    raises Dev::CommandExecutor::ProjectExecutionUnavailableError
  end

  test "an overridden command dispatches to the overridden strategy" do
    Given "a composite whose overridden strategy expects the dispatch"
    command = Dev::OverriddenCommand.new(
      builtin: FakeBuiltin.new,
      project: Dev::ProjectCommand.new(run: "./bin/up.rb", desc: "Setup", container: false),
    )
    context = build_context
    strategies = build_strategies
    strategies.fetch(:overridden_executor)
      .expects(:execute).with(command, args: [], context: context).once
    executor = Dev::CommandExecutor.new(**strategies)

    When "executing"
    executor.execute(command, args: [], context: context)

    Then "the expectation held and no other strategy was consulted"
    true
  end
end
