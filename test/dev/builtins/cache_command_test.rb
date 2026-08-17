# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/cache_command"
require "dev/build_container_config"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::CacheCommandTest < Minitest::Test
  include SorbetHelper

  test "gc runs with the default retention when --keep is absent" do
    Given "a cache command over an expecting GC"
    gc = typed_mock(Dev::Deps::CacheGc)
    gc.expects(:gc).with(keep: Dev::Deps::CacheGc::DEFAULT_KEEP, image_ref: nil, live_tag: nil).once
    command = build_command(gc)

    When "running cache gc"
    command.call(args: ["gc"], context: build_context)

    Then "the expectation on the GC holds"
    true
  end

  test "gc honors the space-separated --keep flag" do
    Given "a cache command over an expecting GC"
    gc = typed_mock(Dev::Deps::CacheGc)
    gc.expects(:gc).with(keep: 5, image_ref: nil, live_tag: nil).once
    command = build_command(gc)

    When "running cache gc --keep 5"
    command.call(args: ["gc", "--keep", "5"], context: build_context)

    Then "the expectation on the GC holds"
    true
  end

  test "gc honors the inline --keep=N flag" do
    Given "a cache command over an expecting GC"
    gc = typed_mock(Dev::Deps::CacheGc)
    gc.expects(:gc).with(keep: 3, image_ref: nil, live_tag: nil).once
    command = build_command(gc)

    When "running cache gc --keep=3"
    command.call(args: ["gc", "--keep=3"], context: build_context)

    Then "the expectation on the GC holds"
    true
  end

  test "gc with a build container also prunes stale images, protecting the live tag" do
    Given "a context with a build container and a pinned live tag"
    config = Dev::BuildContainerConfig.new(image: "myapp-linux", registry: "myregistry")
    gc = typed_mock(Dev::Deps::CacheGc)
    gc.expects(:gc).with(
      keep: Dev::Deps::CacheGc::DEFAULT_KEEP,
      image_ref: "myregistry/myapp-linux",
      live_tag: "myregistry/myapp-linux:content-abc123",
    ).once
    command = build_command(gc)
    context = build_context(build_container: config)
    BuildContainer.stubs(:image_with_tag)
      .with(config, project_root: context.project_root)
      .returns("myregistry/myapp-linux:content-abc123")

    When "running cache gc"
    command.call(args: ["gc"], context: context)

    Then "the expectation on the GC holds"
    true
  end

  test "an unknown subcommand raises the usage error" do
    Given "a cache command"
    command = build_command(typed_mock(Dev::Deps::CacheGc))

    When "running an unsupported subcommand"
    command.call(args: ["warm"], context: build_context)

    Then
    raises ArgumentError
  end

  private

  def build_command(gc)
    Dev::Builtins::CacheCommand.new(cache_gc_factory: ->(_lockfile) { gc })
  end

  def build_context(build_container: nil)
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      ruby_version: "4.0.1",
      project_root: Pathname.new("/tmp/cache-test"),
      build_container: build_container,
    )
  end
end
