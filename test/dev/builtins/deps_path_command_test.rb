# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/deps_path_command"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::DepsPathCommandTest < Minitest::Test
  include SorbetHelper

  test "traits: guarded like any read command, never stamps, lifecycle section" do
    Given "the builtin"
    command = Dev::Builtins::DepsPathCommand.new

    Expect "the declarative traits"
    command.staleness_exempt? == false
    command.stamps? == false
    command.category == Dev::Command::Category::Lifecycle
  end

  test "call builds the accessor over the project in hand and asks it for the path" do
    Given "a factory that records its root and an expecting accessor"
    root = Pathname.new("/tmp/deps-test")
    accessor = typed_mock(Dev::Deps::Accessor)
    accessor.expects(:print_path).with(["ficsit", "some-mod", "linux"]).once
    factory_roots = []
    command = Dev::Builtins::DepsPathCommand.new(
      accessor_factory: ->(project_root) {
        factory_roots << project_root
        accessor
      },
    )

    When "running deps path"
    command.call(args: ["ficsit", "some-mod", "linux"], context: build_context(root))

    Then "the accessor was scoped to the project root"
    factory_roots == [root]
  end

  test "the default factory wires a real accessor over the project lockfile" do
    Given "a command with its default collaborators over an empty project"
    root = Pathname.new(Dir.mktmpdir("deps-default-"))
    command = Dev::Builtins::DepsPathCommand.new

    When "running deps path with no integration"
    command.call(args: [], context: build_context(root))

    Then "the real accessor answers with its own usage contract"
    raises Dev::Deps::Accessor::UsageError

    Cleanup
    FileUtils.rm_rf(root)
  end

  private

  def build_context(project_root)
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(name: "TestProject", root: project_root, ruby_version: "4.0.1"),
    )
  end
end
