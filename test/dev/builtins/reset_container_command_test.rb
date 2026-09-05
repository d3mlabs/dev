# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/reset_container_command"
require "dev/build_container_config"
require "pathname"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::ResetContainerCommandTest < Minitest::Test
  include SorbetHelper

  test "call removes the persistent container and reports what went" do
    Given "a context with a build container and a stubbed docker boundary"
    config = Dev::BuildContainerConfig.new(image: "myapp-linux", registry: "myregistry", persist: true)
    context = build_context(config)
    Dev::BuildContainer.stubs(:image_with_tag).returns("myregistry/myapp-linux:content-abc123")
    Dev::BuildContainer.stubs(:reset_service!).returns(["dev-myapp-linux-content-abc123"])
    command = Dev::Builtins::ResetContainerCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running reset-container"
    command.call(args: [], context: context)

    Then "the removed container is reported"
    $stdout.string.include?("removed dev-myapp-linux-content-abc123")

    Cleanup
    $stdout = old_stdout
  end

  test "call reports when there is nothing to remove" do
    Given "a docker boundary with no persistent container"
    config = Dev::BuildContainerConfig.new(image: "myapp-linux", registry: "myregistry", persist: true)
    context = build_context(config)
    Dev::BuildContainer.stubs(:image_with_tag).returns("myregistry/myapp-linux:content-abc123")
    Dev::BuildContainer.stubs(:reset_service!).returns([])
    command = Dev::Builtins::ResetContainerCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running reset-container"
    command.call(args: [], context: context)

    Then "the no-op is reported"
    $stdout.string.include?("no persistent build container")

    Cleanup
    $stdout = old_stdout
  end

  private

  def build_context(build_container)
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      ruby_version: "4.0.1",
      project_root: Pathname.new("/tmp/reset-container-test"),
      build_container: build_container,
    )
  end
end
