# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/builtins/check_command"
require "pathname"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Cli::Builtins::CheckCommandTest < Minitest::Test
  include SorbetHelper

  test "traits: staleness-exempt (it IS the explicit inspection), never stamps" do
    Given "the builtin"
    command = Dev::Cli::Builtins::CheckCommand.new(dependency_service: typed_mock(Dev::Cli::DependencyService))

    Expect "the declarative traits"
    command.staleness_exempt? == true
    command.stamps? == false
  end

  test "call reports an in-sync dependency state" do
    Given "a dependency service with no staleness messages"
    dependency_service = typed_mock(Dev::Cli::DependencyService)
    dependency_service.stubs(:messages).returns([])
    command = Dev::Cli::Builtins::CheckCommand.new(dependency_service: dependency_service)
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running check"
    command.call(args: no_args, context: build_context)

    Then "the sync confirmation is printed and the process keeps its exit code"
    $stdout.string.include?("in sync")

    Cleanup
    $stdout = old_stdout
  end

  test "call reports each staleness message and exits 1" do
    Given "a dependency service with drifted layers"
    dependency_service = typed_mock(Dev::Cli::DependencyService)
    dependency_service.stubs(:messages).returns(["lockfiles are stale", "install is stale"])
    command = Dev::Cli::Builtins::CheckCommand.new(dependency_service: dependency_service)
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "running check"
    command.call(args: no_args, context: build_context)

    Then "every message reaches stderr"
    $stderr.string.include?("lockfiles are stale")
    $stderr.string.include?("install is stale")

    Cleanup
    $stderr = old_stderr
  end

  private

  def build_context
    Dev::Cli::ExecutionContext.new(
      ui: typed_mock(Dev::Ui),
      project: Dev::Cli::ProjectContext.new(name: "TestProject", root: Pathname.new("/tmp/check-test")),
    )
  end
end
