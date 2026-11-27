# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/overridden_executor"
require "dev/cli/command"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Cli::OverriddenExecutorTest < Minitest::Test
  include SorbetHelper

  # Builtin fake whose stamping trait drives the tail-message choice (the
  # OverriddenCommand delegates stamps? to its builtin slot).
  class FakeBuiltin < Dev::Cli::BuiltinCommand
    def initialize(stamps:)
      @stamps = stamps
      super()
    end

    def desc
      "a builtin"
    end

    def category
      Dev::Cli::Command::Category::Workflow
    end

    def stamps?
      @stamps
    end

    def call(args:, context:); end
  end

  def build_context
    ui = typed_mock(Dev::Ui)
    Dev::Cli::ExecutionContext.new(
      ui: ui,
      project: Dev::Cli::ProjectContext.new(name: "TestProject", root: Pathname.new("/tmp/overridden-executor")),
    )
  end

  def build_command(stamps:)
    Dev::Cli::OverriddenCommand.new(
      builtin: FakeBuiltin.new(stamps: stamps),
      project: Dev::Cli::ProjectCommand.new(run: "./bin/up.rb", desc: "Setup"),
    )
  end

  # Regression lineage of dev#85: a stamping slot's project tail must be
  # the waiting message, so the caller's installed stamp after execute
  # stays reachable.
  test "a stamping slot runs the builtin stage first, then the waiting project tail" do
    Given "a stamping overridden slot over strict strategies"
    command = build_command(stamps: true)
    context = build_context
    builtin_executor = typed_mock(Dev::Cli::BuiltinExecutor)
    project_executor = typed_mock(Dev::Cli::ProjectExecutor)
    executor = Dev::Cli::OverriddenExecutor.new(builtin_executor:, project_executor:)
    args = Dev::Cli::ParsedArgs.new(words: ["--fast"], switches: ["--fast"])
    # call order: the builtin stage is the slot's super(); the project tail owns the slot after it, never before
    stage_then_tail = sequence("builtin stage, then project tail")
    builtin_executor.expects(:execute).with(command.builtin, args: args, context: context).once.in_sequence(stage_then_tail)
    project_executor.expects(:run_waiting).with(command.project, args: ["--fast"]).once.in_sequence(stage_then_tail)

    When "executing the overridden command"
    executor.execute(command, args: args, context: context)

    Then "builtin super() ran first, the tail was run_waiting with the words, and the exec tail was never sent"
    0 * project_executor.exec_into
  end

  test "a non-stamping slot runs the builtin stage first, then the exec tail-call" do
    Given "a non-stamping overridden slot over strict strategies"
    command = build_command(stamps: false)
    context = build_context
    builtin_executor = typed_mock(Dev::Cli::BuiltinExecutor)
    project_executor = typed_mock(Dev::Cli::ProjectExecutor)
    executor = Dev::Cli::OverriddenExecutor.new(builtin_executor:, project_executor:)
    # call order: the exec tail replaces the process, so a builtin stage after it would never run
    stage_then_tail = sequence("builtin stage, then project tail")
    builtin_executor.expects(:execute).with(command.builtin, args: no_args, context: context).once.in_sequence(stage_then_tail)
    project_executor.expects(:exec_into).with(command.project, args: []).once.in_sequence(stage_then_tail)

    When "executing the overridden command"
    executor.execute(command, args: no_args, context: context)

    Then "builtin super() ran first, the tail was exec_into with the words, and the waiting tail was never sent"
    0 * project_executor.run_waiting
  end
end
