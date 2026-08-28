# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/deps_command"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::DepsCommandTest < Minitest::Test
  include SorbetHelper

  test "traits: guarded like any read command, never stamps" do
    Given "the builtin"
    command = Dev::Builtins::DepsCommand.new

    Expect "the declarative traits"
    command.staleness_exempt? == false
    command.stamps? == false
  end

  test "call builds the accessor over the project in hand and dispatches argv" do
    Given "a factory that records its root and an expecting accessor"
    root = Pathname.new("/tmp/deps-test")
    accessor = typed_mock(Dev::Deps::Accessor)
    accessor.expects(:run).with(["path", "ficsit", "some-mod", "linux"]).once
    factory_roots = []
    command = Dev::Builtins::DepsCommand.new(
      accessor_factory: ->(project_root) {
        factory_roots << project_root
        accessor
      },
    )

    When "running deps"
    command.call(args: ["path", "ficsit", "some-mod", "linux"], context: build_context(root))

    Then "the accessor was scoped to the project root"
    factory_roots == [root]
  end

  test "the default factory wires a real accessor over the project lockfile" do
    Given "a command with its default collaborators over an empty project"
    root = Pathname.new(Dir.mktmpdir("deps-default-"))
    command = Dev::Builtins::DepsCommand.new

    When "running deps with no subcommand"
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
      project: Dev::ProjectContext.new(root: project_root, ruby_version: "4.0.1"),
    )
  end
end
