# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/check_command"
require "pathname"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::CheckCommandTest < Minitest::Test
  include SorbetHelper

  test "traits: staleness-exempt (it IS the explicit inspection), never stamps" do
    Given "the builtin"
    command = Dev::Builtins::CheckCommand.new(dependency_service: typed_mock(Dev::DependencyService))

    Expect "the declarative traits"
    command.staleness_exempt? == true
    command.stamps? == false
  end

  test "call reports an in-sync dependency state" do
    Given "a dependency service with no staleness messages"
    dependency_service = typed_mock(Dev::DependencyService)
    dependency_service.stubs(:messages).returns([])
    command = Dev::Builtins::CheckCommand.new(dependency_service: dependency_service)
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running check"
    command.call(args: [], context: build_context)

    Then "the sync confirmation is printed and the process keeps its exit code"
    $stdout.string.include?("in sync")

    Cleanup
    $stdout = old_stdout
  end

  test "call reports each staleness message and exits 1" do
    Given "a dependency service with drifted layers"
    dependency_service = typed_mock(Dev::DependencyService)
    dependency_service.stubs(:messages).returns(["lockfiles are stale", "install is stale"])
    command = Dev::Builtins::CheckCommand.new(dependency_service: dependency_service)
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "running check"
    command.call(args: [], context: build_context)

    Then "every message reaches stderr"
    $stderr.string.include?("lockfiles are stale")
    $stderr.string.include?("install is stale")

    Cleanup
    $stderr = old_stderr
  end

  private

  def build_context
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(root: Pathname.new("/tmp/check-test"), ruby_version: "4.0.1"),
    )
  end
end
