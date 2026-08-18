# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/overridden_executor"
require "dev/command"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::OverriddenExecutorTest < Minitest::Test
  include SorbetHelper

  # Builtin fake whose stamping trait drives the tail-message choice (the
  # OverriddenCommand delegates stamps? to its builtin slot).
  class FakeBuiltin < Dev::BuiltinCommand
    def initialize(stamps:)
      @stamps = stamps
      super()
    end

    def desc = "a builtin"

    def stamps? = @stamps

    def call(args:, context:); end
  end

  def build_context
    ui = typed_mock(Dev::Cli::Ui)
    Dev::ExecutionContext.new(ui: ui, ruby_version: "4.0.1", project_root: Pathname.new("/tmp/overridden-executor"))
  end

  def build_command(stamps:)
    Dev::OverriddenCommand.new(
      builtin: FakeBuiltin.new(stamps: stamps),
      project: Dev::ProjectCommand.new(run: "./bin/up.rb", desc: "Setup", container: false),
    )
  end

  # Recording strategy mocks: stages captures every dispatch in order, and
  # any message a test doesn't stub is an unexpected invocation — so each
  # test also proves the other tail message was never sent.
  def build_strategies(stages)
    builtin_executor = typed_mock(Dev::BuiltinExecutor)
    builtin_executor.stubs(:execute).with { |cmd, args:, context:|
      stages << [:builtin_stage, cmd, args, context]
      true }
    project_executor = typed_mock(Dev::ProjectExecutor)
    { builtin_executor: builtin_executor, project_executor: project_executor }
  end

  # Regression lineage of dev#85: a stamping slot's project tail must be
  # the waiting message, so the caller's installed stamp after execute
  # stays reachable.
  test "a stamping slot runs the builtin stage first, then the waiting project tail" do
    Given "a stamping overridden slot over recording strategies"
    command = build_command(stamps: true)
    context = build_context
    stages = []
    strategies = build_strategies(stages)
    strategies.fetch(:project_executor).stubs(:run_waiting).with { |cmd, args:, context:|
      stages << [:project_tail, cmd, args, context]
      true }
    executor = Dev::OverriddenExecutor.new(**strategies)

    When "executing the overridden command"
    executor.execute(command, args: ["--fast"], context: context)

    Then "builtin super() ran first, and the tail was run_waiting with the exact project half"
    stages == [
      [:builtin_stage, command.builtin, ["--fast"], context],
      [:project_tail, command.project, ["--fast"], context],
    ]
  end

  test "a non-stamping slot runs the builtin stage first, then the exec tail-call" do
    Given "a non-stamping overridden slot over recording strategies"
    command = build_command(stamps: false)
    context = build_context
    stages = []
    strategies = build_strategies(stages)
    strategies.fetch(:project_executor).stubs(:exec_into).with { |cmd, args:, context:|
      stages << [:project_tail, cmd, args, context]
      true }
    executor = Dev::OverriddenExecutor.new(**strategies)

    When "executing the overridden command"
    executor.execute(command, args: [], context: context)

    Then "builtin super() ran first, and the tail was exec_into with the exact project half"
    stages == [
      [:builtin_stage, command.builtin, [], context],
      [:project_tail, command.project, [], context],
    ]
  end
end
