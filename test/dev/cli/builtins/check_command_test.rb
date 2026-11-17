# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/builtins/check_command"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "fileutils"
require "pathname"
require "stringio"
require "tmpdir"

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

  test "call names each pin the lock cannot keep, so a lock that moves on every update is no surprise" do
    Given "an in-sync project whose lock holds a steam branch tip and a sourced formula"
    root = Pathname.new(Dir.mktmpdir("check-unkeepable-"))
    Dev::Deps::Lockfile.new(dir: root).lock([
      Dev::Deps::Dependency.new(name: "zlib", integration: :brew, group: :app, version: "1.3", hash: nil,
        source: "homebrew/core@0f1ba9ea", metadata: {}),
      Dev::Deps::Dependency.new(name: "SatisfactoryServer", integration: :steam, group: :app, version: "15400000", hash: nil,
        metadata: { "app" => "1690800", "branch" => "public" }),
    ])
    dependency_service = typed_mock(Dev::Cli::DependencyService)
    dependency_service.stubs(:messages).returns([])
    command = Dev::Cli::Builtins::CheckCommand.new(dependency_service: dependency_service)
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running check"
    command.call(args: no_args, context: build_context(root))

    Then "the tip is named with why, the formula is not, and the verdict still prints"
    $stdout.string.include?("dev: steam/SatisfactoryServer 15400000: re-resolved on every dev deps update")
    !$stdout.string.include?("zlib")
    $stdout.string.include?("in sync")

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  private

  def build_context(root = Pathname.new("/tmp/check-test"))
    Dev::Cli::ExecutionContext.new(
      ui: typed_mock(Dev::Ui),
      project: Dev::Cli::ProjectContext.new(name: "TestProject", root:),
    )
  end
end
