# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/update_deps_command"
require "fileutils"
require "pathname"
require "stringio"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::UpdateDepsCommandTest < Minitest::Test
  include SorbetHelper

  test "traits: staleness-exempt (it IS the remediation), never stamps" do
    Given "the builtin"
    command = Dev::Builtins::UpdateDepsCommand.new

    Expect "the declarative traits"
    command.staleness_exempt? == true
    command.stamps? == false
    !command.hidden?
    command.desc.include?("lockfiles")
  end

  test "call resolves an empty manifest and reports the update" do
    Given "a project root with no dependencies.rb"
    root = Pathname.new(Dir.mktmpdir("update-deps-empty-"))
    command = Dev::Builtins::UpdateDepsCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running update-deps"
    command.call(args: [], context: build_context(root))

    Then "the run completes and points at dev up"
    $stdout.string.include?("lockfiles updated")

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "call does not mistake a previously loaded project's config for this one" do
    Given "a stale config from an earlier load, and a dependencies.rb that never calls Dev::Deps.define"
    Dev::Deps.define { ruby "9.9.9" }
    root = Pathname.new(Dir.mktmpdir("update-deps-stale-"))
    File.write(root / "dependencies.rb", "UPDATE_DEPS_TEST_CONSTANT = 1 unless defined?(UPDATE_DEPS_TEST_CONSTANT)\n")
    command = Dev::Builtins::UpdateDepsCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running update-deps"
    command.call(args: [], context: build_context(root))

    Then "the run resolved an empty config (a leaked ruby pin would try to resolve it)"
    Dev::Deps.last_config.ruby_version_requirement.nil?

    Cleanup
    $stdout = old_stdout
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
