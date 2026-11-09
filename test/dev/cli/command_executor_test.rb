# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/command_executor"
require "dev/cli/command"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Cli::CommandExecutorTest < Minitest::Test
  include SorbetHelper

  # Minimal builtin fake: the composite only dispatches on the variant's
  # type, so the fake carries no behavior — the strategy mock receives it
  # untouched.
  class FakeBuiltin < Dev::Cli::BuiltinCommand
    def desc = "a builtin"

    def category = Dev::Cli::Command::Category::Workflow

    def call(args:, context:); end
  end

  # Minimal lifecycle verb fake, for the same reason: the composite reads
  # only the variant's type.
  class FakeVerb < Dev::Cli::LifecycleCommand
    Env = type_member { { fixed: String } }

    def desc = "a verb"

    def before(args:, context:) = Dev::Cli::Dispatch::Outcome::Done.new

    def seam(env, context:); end

    def after(env, context:); end
  end

  def build_context
    ui = typed_mock(Dev::Ui)
    Dev::Cli::ExecutionContext.new(
      ui: ui,
      project: Dev::Cli::ProjectContext.new(name: "TestProject", root: Pathname.new("/tmp/executor-test")),
    )
  end

  # Strategy mocks are strict: any message a test doesn't expect is an
  # unexpected invocation, so each arm proves the other four stayed silent.
  def build_strategies
    {
      builtin_executor: typed_mock(Dev::Cli::BuiltinExecutor),
      group_executor: typed_mock(Dev::Cli::GroupExecutor),
      project_executor: typed_mock(Dev::Cli::ProjectExecutor),
      overridden_executor: typed_mock(Dev::Cli::OverriddenExecutor),
      lifecycle_executor: typed_mock(Dev::Cli::LifecycleExecutor),
    }
  end

  test "a lifecycle verb dispatches to the lifecycle strategy with exact args" do
    Given "a composite whose lifecycle strategy expects the dispatch"
    command = FakeVerb.new
    context = build_context
    strategies = build_strategies
    args = Dev::Cli::ParsedArgs.new(words: ["cellbound-3d-win64-dev"], positionals: ["cellbound-3d-win64-dev"])
    strategies.fetch(:lifecycle_executor)
      .expects(:execute).with(command, args: args, context: context).once
    executor = Dev::Cli::CommandExecutor.new(**strategies)

    When "executing"
    executor.execute(command, args: args, context: context)

    Then "the expectation held and no other strategy was consulted"
    true
  end

  test "a lifecycle verb against a builtin-only composite is a wiring bug" do
    Given "a composite wired without project arms (the projectless wiring)"
    executor = build_builtin_only_executor

    When "executing"
    executor.execute(FakeVerb.new, args: no_args, context: build_context)

    Then
    raises Dev::Cli::CommandExecutor::ProjectExecutionUnavailableError
  end

  test "a command group dispatches to the group strategy" do
    Given "a composite whose group strategy expects the dispatch"
    command = Dev::Cli::CommandGroup.new(
      path: ["deps"], desc: "Dependency lookups", category: Dev::Cli::Command::Category::Environment,
      children: { "path" => FakeBuiltin.new },
    )
    strategies = build_strategies
    strategies.fetch(:group_executor).expects(:execute).with(command).once
    executor = Dev::Cli::CommandExecutor.new(**strategies)

    When "executing"
    executor.execute(command, args: no_args, context: build_context)

    Then "the expectation held and no other strategy was consulted"
    true
  end

  test "a builtin command dispatches to the builtin strategy with exact args" do
    Given "a composite whose builtin strategy expects the dispatch"
    command = FakeBuiltin.new
    context = build_context
    strategies = build_strategies
    args = Dev::Cli::ParsedArgs.new(words: ["--verbose"], switches: ["--verbose"])
    strategies.fetch(:builtin_executor)
      .expects(:execute).with(command, args: args, context: context).once
    executor = Dev::Cli::CommandExecutor.new(**strategies)

    When "executing"
    executor.execute(command, args: args, context: context)

    Then "the expectation held and no other strategy was consulted"
    true
  end

  test "a project command dispatches to the project strategy's exec tail-call" do
    Given "a composite whose project strategy expects exec_into"
    command = Dev::Cli::ProjectCommand.new(run: "./bin/test.sh", desc: "Run tests")
    context = build_context
    strategies = build_strategies
    strategies.fetch(:project_executor)
      .expects(:exec_into).with(command, args: ["--fast", "spec/a"]).once
    executor = Dev::Cli::CommandExecutor.new(**strategies)

    When "executing with the script's words"
    executor.execute(command, args: Dev::Cli::ParsedArgs.new(words: ["--fast", "spec/a"], positionals: ["--fast", "spec/a"]), context: context)

    Then "the expectation held with the words, and no other strategy was consulted"
    true
  end

  test "a project command against a builtin-only composite is a wiring bug" do
    Given "a composite wired without project arms (the projectless wiring)"
    command = Dev::Cli::ProjectCommand.new(run: "./bin/test.sh", desc: "Run tests")
    executor = build_builtin_only_executor

    When "executing"
    executor.execute(command, args: no_args, context: build_context)

    Then
    raises Dev::Cli::CommandExecutor::ProjectExecutionUnavailableError
  end

  test "an overridden command against a builtin-only composite is a wiring bug" do
    Given "a composite wired without project arms (the projectless wiring)"
    command = Dev::Cli::OverriddenCommand.new(
      builtin: FakeBuiltin.new,
      project: Dev::Cli::ProjectCommand.new(run: "./bin/up.rb", desc: "Setup"),
    )
    executor = build_builtin_only_executor

    When "executing"
    executor.execute(command, args: no_args, context: build_context)

    Then
    raises Dev::Cli::CommandExecutor::ProjectExecutionUnavailableError
  end

  # The projectless wiring: builtin and group arms only.
  def build_builtin_only_executor
    Dev::Cli::CommandExecutor.new(
      builtin_executor: typed_mock(Dev::Cli::BuiltinExecutor),
      group_executor: typed_mock(Dev::Cli::GroupExecutor),
    )
  end

  test "an overridden command dispatches to the overridden strategy" do
    Given "a composite whose overridden strategy expects the dispatch"
    command = Dev::Cli::OverriddenCommand.new(
      builtin: FakeBuiltin.new,
      project: Dev::Cli::ProjectCommand.new(run: "./bin/up.rb", desc: "Setup"),
    )
    context = build_context
    strategies = build_strategies
    strategies.fetch(:overridden_executor)
      .expects(:execute).with(command, args: no_args, context: context).once
    executor = Dev::Cli::CommandExecutor.new(**strategies)

    When "executing"
    executor.execute(command, args: no_args, context: context)

    Then "the expectation held and no other strategy was consulted"
    true
  end
end
