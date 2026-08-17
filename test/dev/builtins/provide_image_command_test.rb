# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/provide_image_command"
require "dev/build_container_config"
require "pathname"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::ProvideImageCommandTest < Minitest::Test
  include SorbetHelper

  test "traits: hidden plumbing, staleness-exempt (fresh CI checkouts have no stamp)" do
    Given "the builtin"
    command = Dev::Builtins::ProvideImageCommand.new

    Expect "the declarative traits"
    command.hidden? == true
    command.staleness_exempt? == true
    command.stamps? == false
  end

  test "call resolves the image and prints its tag to stdout" do
    Given "a context with a build container and a stubbed resolution boundary"
    config = Dev::BuildContainerConfig.new(image: "myapp-linux", registry: "myregistry")
    context = build_context(config)
    BuildContainer.stubs(:ensure_image!).returns("myregistry/myapp-linux:content-abc123")
    command = Dev::Builtins::ProvideImageCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running provide-image"
    command.call(args: [], context: context)

    Then "the tag is the only stdout payload, so a workflow can capture it"
    $stdout.string == "myregistry/myapp-linux:content-abc123\n"

    Cleanup
    $stdout = old_stdout
  end

  private

  def build_context(build_container)
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      ruby_version: "4.0.1",
      project_root: Pathname.new("/tmp/provide-image-test"),
      build_container: build_container,
    )
  end
end
