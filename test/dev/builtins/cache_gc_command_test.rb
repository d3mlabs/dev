# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/cache_gc_command"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/environment_image"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::CacheGcCommandTest < Minitest::Test
  include SorbetHelper

  test "cache gc is a maintenance verb: exempt from the staleness guard, never stamps" do
    Given "a cache command"
    command = build_command(typed_mock(Dev::Deps::CacheGc))

    Expect "the declarative traits"
    command.staleness_exempt? == true
    command.stamps? == false
    command.category == Dev::Command::Category::Workflow
    !command.hidden?
  end

  test "gc runs with the default retention when --keep is absent" do
    Given "a cache command over an expecting GC"
    gc = typed_mock(Dev::Deps::CacheGc)
    gc.expects(:gc).with(keep: Dev::Deps::CacheGc::DEFAULT_KEEP, images: [], tool_caches: false).once
    command = build_command(gc)

    When "running cache gc"
    command.call(args: no_args, context: build_context)

    Then "the expectation on the GC holds"
    true
  end

  test "gc drops the tool caches only when --tool-caches is given" do
    Given "a cache command over an expecting GC"
    gc = typed_mock(Dev::Deps::CacheGc)
    gc.expects(:gc).with(keep: Dev::Deps::CacheGc::DEFAULT_KEEP, images: [], tool_caches: true).once
    command = build_command(gc)

    When "running cache gc --tool-caches"
    command.call(args: parsed_args(command, ["--tool-caches"]), context: build_context)

    Then "the expectation on the GC holds"
    true
  end

  test "gc honors the space-separated --keep flag" do
    Given "a cache command over an expecting GC"
    gc = typed_mock(Dev::Deps::CacheGc)
    gc.expects(:gc).with(keep: 5, images: [], tool_caches: false).once
    command = build_command(gc)

    When "running cache gc --keep 5"
    command.call(args: parsed_args(command, ["--keep", "5"]), context: build_context)

    Then "the expectation on the GC holds"
    true
  end

  test "gc honors the inline --keep=N flag" do
    Given "a cache command over an expecting GC"
    gc = typed_mock(Dev::Deps::CacheGc)
    gc.expects(:gc).with(keep: 3, images: [], tool_caches: false).once
    command = build_command(gc)

    When "running cache gc --keep=3"
    command.call(args: parsed_args(command, ["--keep=3"]), context: build_context)

    Then "the expectation on the GC holds"
    true
  end

  test "gc is handed the lock's pinned images: what the docker half keeps" do
    Given "a checkout whose lock pins one image"
    root = Dir.mktmpdir("cache-gc-command-test")
    pin = Dev::Deps::Dependency.new(
      name: "snappy-linux", integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}",
      metadata: {
        "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platform" => "linux/amd64",
        "platforms" => ["linux/amd64"], "registry" => "ghcr.io/d3mlabs", "apt" => [],
      },
    )
    Dev::Deps::Lockfile.new(dir: Pathname(root)).lock(Dev::EnvironmentImage.stamp([pin]))
    gc = typed_mock(Dev::Deps::CacheGc)
    gc.expects(:gc).with { |images:, **| images.map(&:name) == ["snappy-linux"] }.once
    command = build_command(gc)

    When "running cache gc in that checkout"
    command.call(args: no_args, context: build_context(root: Pathname(root)))

    Then "the expectation on the GC holds"
    true

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "gc prunes the snapshot branches of the project's origin after the local tiers" do
    Given "a cache command over a GC and a snapshot namespace, both expecting"
    order = sequence("tiers")
    gc = typed_mock(Dev::Deps::CacheGc)
    gc.expects(:gc).once.in_sequence(order)
    branches = typed_mock(Dev::Lifecycle::SnapshotBranches)
    branches.expects(:prune).with.once.in_sequence(order).returns([])
    command = build_command(gc, snapshot_branches: branches)

    When "running cache gc"
    command.call(args: no_args, context: build_context)

    Then "the expectations hold, in order"
    true
  end

  test "the default factories build the real GC over the project lockfile and the snapshot namespace over its checkout" do
    Given "a command with its default collaborators"
    # The real CacheGc#gc shells out to docker and the real prune to git, so
    # the test intercepts both construction boundaries and asserts the
    # default factories' composition.
    root = Pathname.new("/tmp/cache-test")
    gc = typed_mock(Dev::Deps::CacheGc)
    gc.expects(:gc).with(keep: Dev::Deps::CacheGc::DEFAULT_KEEP, images: [], tool_caches: false).once
    Dev::Deps::CacheGc.expects(:new)
      .with { |**kwargs| kwargs.fetch(:lockfile).is_a?(Dev::Deps::Lockfile) }
      .returns(gc)
    branches = typed_mock(Dev::Lifecycle::SnapshotBranches)
    branches.expects(:prune).once.returns([])
    Dev::Lifecycle::SnapshotBranches.expects(:new)
      .with { |**kwargs| kwargs.fetch(:git).root == root }
      .returns(branches)
    command = Dev::Builtins::CacheGcCommand.new

    When "running cache gc"
    command.call(args: no_args, context: build_context(root:))

    Then "the expectations on the construction boundaries hold"
    true
  end

  private

  def build_command(gc, snapshot_branches: quiet_snapshot_branches)
    Dev::Builtins::CacheGcCommand.new(
      cache_gc_factory: ->(_lockfile) { gc },
      snapshot_branches_factory: ->(_root) { snapshot_branches },
    )
  end

  # A namespace with nothing to prune, for the tests about the other tiers.
  def quiet_snapshot_branches
    branches = typed_mock(Dev::Lifecycle::SnapshotBranches)
    branches.stubs(:prune).returns([])
    branches
  end

  def build_context(root: Pathname.new("/tmp/cache-test"))
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Ui),
      project: Dev::ProjectContext.new(name: "TestProject", root: root),
    )
  end
end
