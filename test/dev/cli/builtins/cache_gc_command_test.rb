# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/builtins/cache_gc_command"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/environment_image"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Cli::Builtins::CacheGcCommandTest < Minitest::Test
  include SorbetHelper

  test "cache gc is a maintenance verb: exempt from the staleness guard, never stamps" do
    Given "a cache command"
    command = build_command(typed_mock(Dev::Deps::CacheGc), typed_mock(Dev::Lifecycle::SnapshotBranches))

    Expect "the declarative traits"
    command.staleness_exempt? == true
    command.stamps? == false
    command.category == Dev::Cli::Command::Category::Workflow
    !command.hidden?
  end

  test "gc runs with the default retention when --keep is absent" do
    Given "a cache command over a GC and a quiet snapshot namespace"
    gc = typed_mock(Dev::Deps::CacheGc)
    branches = typed_mock(Dev::Lifecycle::SnapshotBranches)
    command = build_command(gc, branches)

    When "running cache gc"
    command.call(args: no_args, context: build_context)

    Then "the GC runs with the default retention"
    1 * gc.gc(keep: Dev::Deps::CacheGc::DEFAULT_KEEP, images: [], tool_caches: false)
    _ * branches.prune >> []
  end

  test "gc drops the tool caches only when --tool-caches is given" do
    Given "a cache command over a GC and a quiet snapshot namespace"
    gc = typed_mock(Dev::Deps::CacheGc)
    branches = typed_mock(Dev::Lifecycle::SnapshotBranches)
    command = build_command(gc, branches)

    When "running cache gc --tool-caches"
    command.call(args: parsed_args(command, ["--tool-caches"]), context: build_context)

    Then "the GC runs with the tool caches included"
    1 * gc.gc(keep: Dev::Deps::CacheGc::DEFAULT_KEEP, images: [], tool_caches: true)
    _ * branches.prune >> []
  end

  test "gc honors the space-separated --keep flag" do
    Given "a cache command over a GC and a quiet snapshot namespace"
    gc = typed_mock(Dev::Deps::CacheGc)
    branches = typed_mock(Dev::Lifecycle::SnapshotBranches)
    command = build_command(gc, branches)

    When "running cache gc --keep 5"
    command.call(args: parsed_args(command, ["--keep", "5"]), context: build_context)

    Then "the GC runs with the given retention"
    1 * gc.gc(keep: 5, images: [], tool_caches: false)
    _ * branches.prune >> []
  end

  test "gc honors the inline --keep=N flag" do
    Given "a cache command over a GC and a quiet snapshot namespace"
    gc = typed_mock(Dev::Deps::CacheGc)
    branches = typed_mock(Dev::Lifecycle::SnapshotBranches)
    command = build_command(gc, branches)

    When "running cache gc --keep=3"
    command.call(args: parsed_args(command, ["--keep=3"]), context: build_context)

    Then "the GC runs with the given retention"
    1 * gc.gc(keep: 3, images: [], tool_caches: false)
    _ * branches.prune >> []
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
    branches = typed_mock(Dev::Lifecycle::SnapshotBranches)
    command = build_command(gc, branches)

    When "running cache gc in that checkout"
    command.call(args: no_args, context: build_context(root: Pathname(root)))

    Then "the GC is handed the one pinned image"
    1 * gc.gc(
      keep: Dev::Deps::CacheGc::DEFAULT_KEEP,
      images: all_of(responds_with(:size, 1), includes(responds_with(:name, "snappy-linux"))),
      tool_caches: false,
    )
    _ * branches.prune >> []

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "gc prunes the snapshot branches of the project's origin alongside the local tiers" do
    Given "a cache command over a GC and a snapshot namespace"
    gc = typed_mock(Dev::Deps::CacheGc)
    branches = typed_mock(Dev::Lifecycle::SnapshotBranches)
    command = build_command(gc, branches)

    When "running cache gc"
    command.call(args: no_args, context: build_context)

    Then "both tiers are collected"
    1 * gc.gc
    1 * branches.prune >> []
  end

  test "the default factories build the real GC over the project lockfile and the snapshot namespace over its checkout" do
    Given "a command with its default collaborators"
    # The real CacheGc#gc shells out to docker and the real prune to git, so
    # the test intercepts both construction boundaries and asserts the
    # default factories' composition.
    root = Pathname.new("/tmp/cache-test")
    gc = typed_mock(Dev::Deps::CacheGc)
    branches = typed_mock(Dev::Lifecycle::SnapshotBranches)
    command = Dev::Cli::Builtins::CacheGcCommand.new

    When "running cache gc"
    command.call(args: no_args, context: build_context(root:))

    Then "the collaborators the factories built are the ones driven"
    1 * Dev::Deps::CacheGc.new(has_entry(lockfile: instance_of(Dev::Deps::Lockfile))) >> gc
    1 * Dev::Lifecycle::SnapshotBranches.new(has_entry(git: responds_with(:root, root))) >> branches
    1 * gc.gc(keep: Dev::Deps::CacheGc::DEFAULT_KEEP, images: [], tool_caches: false)
    1 * branches.prune >> []
  end

  private

  def build_command(gc, snapshot_branches)
    Dev::Cli::Builtins::CacheGcCommand.new(
      cache_gc_factory: ->(_lockfile, _ui) { gc },
      snapshot_branches_factory: ->(_root) { snapshot_branches },
    )
  end

  def build_context(root: Pathname.new("/tmp/cache-test"))
    Dev::Cli::ExecutionContext.new(
      ui: typed_mock(Dev::Ui),
      project: Dev::Cli::ProjectContext.new(name: "TestProject", root: root),
    )
  end
end
