# typed: false
# frozen_string_literal: true

require "fileutils"
require "test_helper"
require "tmpdir"
require "dev/deps/gh_integration"
require "dev/deps/local_store"
require "dev/stream"
require "dev/stream_follower"
require "dev/stream_head_lookup"
require "dev/stream_store"
require "support/recording_ui"

# The gh integration's install seam: records what it was asked to install
# and publishes each pin's tree into the store, as the real one does.
class PublishingGhIntegration < Dev::Deps::GhIntegration
  attr_reader :installed

  def initialize(store:)
    super(repository: nil, store: store)
    @local = store
    @installed = []
  end

  def install_all(dependencies)
    @installed.concat(dependencies)
    dependencies.each do |dep|
      key = Dev::Deps::GhIntegration.tree_key(dep)
      next if @local.tree(key)

      @local.publish_tree(key) do |staging|
        FileUtils.mkdir_p(staging / "bin")
        staging
      end
    end
  end
end

transform!(RSpock::AST::Transformation)
class Dev::StreamFollowerTest < Minitest::Test
  include SorbetHelper

  STREAM = Dev::Stream.parse("d3mlabs/ai-flow@gh ~> 1")
  HEAD = Dev::Stream::Head.new(version: "1.3.0", commit: "c0ffee0000000000000000000000000000000001")

  test "following installs the head's pin through the gh integration and appends the tree's bin to the job's PATH" do
    Given "a head on gh, an empty store whose install publishes the tree, a job's GITHUB_PATH file with a line already"
    local = Dev::Deps::LocalStore.new(data_root: Dir.mktmpdir("follower"))
    store = Dev::StreamStore.new(store: local)
    expected_dep = store.dependency(STREAM, HEAD)
    integration = PublishingGhIntegration.new(store: local)
    github_path = File.join(Dir.mktmpdir("job"), "add_path")
    File.write(github_path, "/opt/first\n")
    ui = RecordingUi.new

    When
    tree = Dev::StreamFollower.new(lookup: lookup, store: store, integration: integration, github_path: github_path, ui: ui).follow!(STREAM)

    Then "the pin was installed; the published tree is answered; its bin is now the last PATH addition; the head and the export are said"
    integration.installed == [expected_dep]
    tree == local.tree(Dev::Deps::GhIntegration.tree_key(expected_dep))
    File.read(github_path) == "/opt/first\n#{tree}/bin\n"
    ui.rows == [
      [:note, "{{v}} d3mlabs/ai-flow@gh ~> 1 is at v1.3.0 (c0ffee000000)", 0],
      [:note, "{{v}} #{tree}/bin exported to the job's PATH", 0],
    ]
  end

  test "outside a job (no GITHUB_PATH) the head is installed and its bin named, nothing exported" do
    Given "an installed head, no GITHUB_PATH"
    local = Dev::Deps::LocalStore.new(data_root: Dir.mktmpdir("follower"))
    store = Dev::StreamStore.new(store: local)
    dep = store.dependency(STREAM, HEAD)
    publish(local, dep)
    integration = PublishingGhIntegration.new(store: local)
    ui = RecordingUi.new

    When
    tree = Dev::StreamFollower.new(lookup: lookup, store: store, integration: integration, github_path: nil, ui: ui).follow!(STREAM)

    Then
    integration.installed == [dep]
    ui.rows.last == [:note, "{{v}} #{tree}/bin is the stream's bin (not in a job: $GITHUB_PATH unset, nothing exported)", 0]
  end

  test "a head the channel does not have is the lookup's error, nothing installed" do
    Given "a lookup with no head"
    failing = typed_mock(Dev::StreamHeadLookup)
    failing.expects(:head).with(STREAM).raises(Dev::StreamHeadLookup::NoHeadError, "d3mlabs/ai-flow@gh ~> 1 has no head")
    local = Dev::Deps::LocalStore.new(data_root: Dir.mktmpdir)
    integration = PublishingGhIntegration.new(store: local)

    When
    Dev::StreamFollower.new(lookup: failing, store: Dev::StreamStore.new(store: local), integration: integration, github_path: nil, ui: RecordingUi.new).follow!(STREAM)

    Then
    raises Dev::StreamHeadLookup::NoHeadError
    integration.installed.empty?
  end

  private

  def lookup
    lookup = typed_mock(Dev::StreamHeadLookup)
    lookup.expects(:head).with(STREAM).returns(HEAD)
    lookup
  end

  def publish(local, dep)
    local.publish_tree(Dev::Deps::GhIntegration.tree_key(dep)) do |staging|
      FileUtils.mkdir_p(staging / "bin")
      staging
    end
  end
end
