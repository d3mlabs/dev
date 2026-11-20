# typed: false
# frozen_string_literal: true

require "fileutils"
require "test_helper"
require "tmpdir"
require "dev/deps/gh_integration"
require "dev/deps/local_store"
require "dev/stream"
require "dev/stream_store"

transform!(RSpock::AST::Transformation)
class Dev::StreamStoreTest < Minitest::Test
  STREAM = Dev::Stream.parse("d3mlabs/ai-flow@gh ~> 1")
  HEAD = Dev::Stream::Head.new(version: "1.3.0", commit: "c0ffee0000000000000000000000000000000001")

  test "a head's pin is the gh tree every gh pin becomes: the repo at the release tag, published as-is, its commit the source" do
    When
    dep = Dev::StreamStore.new(store: store).dependency(STREAM, HEAD)

    Then "the dependency vocabulary GhIntegration installs from"
    dep.name == "ai-flow"
    dep.integration == :gh
    dep.group == :app
    dep.version == "v1.3.0"
    dep.source == HEAD.commit
    dep.metadata == { "repo" => "d3mlabs/ai-flow", "build" => "none", "commit" => HEAD.commit }
    Dev::Deps::GhIntegration.tree_key(dep).base == "~/.dev/gh/d3mlabs/ai-flow"
    Dev::Deps::GhIntegration.tree_key(dep).version == "v1.3.0"
  end

  test "before anything is published a head has no tree and the stream nothing installed" do
    Given "an empty store"
    stream_store = Dev::StreamStore.new(store: store)

    Expect
    stream_store.tree(STREAM, HEAD).nil?
    stream_store.installed(STREAM).nil?
  end

  test "the head's tree is where the store published it" do
    Given "a store"
    local = store
    stream_store = Dev::StreamStore.new(store: local)

    When "the head's tree is published"
    published = publish(local, "v1.3.0")

    Then
    stream_store.tree(STREAM, HEAD) == published
    stream_store.installed(STREAM) == "1.3.0"
  end

  test "installed is the greatest release of the series with a published tree: other series, the series tag, and a tree without its marker do not count" do
    Given "trees of two series, an unmarked v1.4.0 (a half-published dir), and a v1 dir"
    local = store
    publish(local, "v1.2.0")
    publish(local, "v1.3.0")
    publish(local, "v2.0.0")
    publish(local, "v0.9.0")
    FileUtils.mkdir_p(File.join(local.tree_path(key("v1.4.0")).to_s))
    FileUtils.mkdir_p(File.join(local.tree_path(key("v1")).to_s))

    Expect
    Dev::StreamStore.new(store: local).installed(STREAM) == "1.3.0"
    Dev::StreamStore.new(store: local).installed(Dev::Stream.parse("d3mlabs/ai-flow@gh ~> 2")) == "2.0.0"
    Dev::StreamStore.new(store: local).installed(Dev::Stream.parse("d3mlabs/ai-flow@gh ~> 3")).nil?
  end

  private

  def store
    Dev::Deps::LocalStore.new(data_root: Dir.mktmpdir("stream-store"))
  end

  def key(tag)
    Dev::Deps::GhIntegration.tree_key(Dev::StreamStore.new(store: store).dependency(STREAM, Dev::Stream::Head.new(version: tag.delete_prefix("v"), commit: "")))
  end

  def publish(local, tag)
    local.publish_tree(key(tag)) do |staging|
      FileUtils.mkdir_p(staging / "bin")
      staging
    end
  end
end
