# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/local_store"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::LocalStoreTest < Minitest::Test
  test "tree_path re-roots a ~/.dev base onto the data root and keys by version" do
    Given "a store over a throwaway data root"
    root = Dir.mktmpdir("local-store-")
    store = Dev::Deps::LocalStore.new(data_root: root)

    Expect "the would-be path, whether or not anything is published there"
    store.tree_path(key(base: "~/.dev/engines/ue", version: "5.6.1")) == Pathname(root) / "engines/ue/5.6.1"
    store.tree_path(key(base: "/opt/engines/ue", version: "5.6.1")) == Pathname("/opt/engines/ue/5.6.1")
    store.tree(key(base: "~/.dev/engines/ue", version: "5.6.1")).nil?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "publish_tree stages on the base's filesystem, stamps the marker and publishes atomically" do
    Given "a store and a key nothing is published for"
    root = Dir.mktmpdir("local-store-")
    store = Dev::Deps::LocalStore.new(data_root: root)
    tree_key = key(base: "~/.dev/engines/ue", version: "5.6.1")
    staging_seen = nil

    When "publishing a tree built inside the yielded staging dir"
    published = store.publish_tree(tree_key) do |staging|
      staging_seen = staging
      (staging / "Engine").mkpath
      (staging / "Engine/Build.version").write("5.6.1")
      staging
    end

    Then "the tree is published at its path with the marker recording the version, staging is gone"
    published == Pathname(root) / "engines/ue/5.6.1"
    store.tree(tree_key) == published
    (published / "Engine/Build.version").read == "5.6.1"
    (published / Dev::Deps::TreeKey::DEFAULT_MARKER).read == "5.6.1"
    staging_seen.to_s.start_with?("#{root}/engines/ue/.staging-")
    !staging_seen.exist?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "publish_tree publishes the subdirectory the block hands back" do
    Given "a store"
    root = Dir.mktmpdir("local-store-")
    store = Dev::Deps::LocalStore.new(data_root: root)
    tree_key = key(base: "~/.dev/engines/ue", version: "5.6.1")

    When "the block builds in a scratch area and returns the finished subtree"
    published = store.publish_tree(tree_key) do |staging|
      (staging / "archives").mkpath
      (staging / "extracted").mkpath
      (staging / "extracted/payload").write("x")
      staging / "extracted"
    end

    Then "only the subtree is published; the scratch siblings never reach the version dir"
    (published / "payload").read == "x"
    !(published / "archives").exist?
    !(published / "extracted").exist?
    store.tree(tree_key) == published

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "publish_tree leaves nothing behind when the block raises" do
    Given "a store"
    root = Dir.mktmpdir("local-store-")
    store = Dev::Deps::LocalStore.new(data_root: root)
    tree_key = key(base: "~/.dev/engines/ue", version: "5.6.1")

    When "the build fails mid-way"
    store.publish_tree(tree_key) do |staging|
      (staging / "half").write("x")
      raise "download failed"
    end

    Then "the error propagates, nothing is published and no staging remains"
    raises RuntimeError
    store.tree(tree_key).nil?
    Dir.children(Pathname(root) / "engines/ue") == []

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "publish_tree is first-writer-wins: an already-published version is never replaced" do
    Given "a published version"
    root = Dir.mktmpdir("local-store-")
    store = Dev::Deps::LocalStore.new(data_root: root)
    tree_key = key(base: "~/.dev/engines/ue", version: "5.6.1")
    store.publish_tree(tree_key) do |staging|
      (staging / "payload").write("first")
      staging
    end

    When "a concurrent publisher finishes second"
    published = store.publish_tree(tree_key) do |staging|
      (staging / "payload").write("second")
      staging
    end

    Then "the first publication stands and the second's staging is cleaned up"
    (published / "payload").read == "first"
    Dir.children(Pathname(root) / "engines/ue") == ["5.6.1"]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "tree honours the key's marker name, so legacy integration markers stay valid" do
    Given "a version dir published by an older dev under the gh marker name"
    root = Dir.mktmpdir("local-store-")
    store = Dev::Deps::LocalStore.new(data_root: root)
    legacy = Pathname(root) / "engines/ue/5.6.1"
    legacy.mkpath
    (legacy / ".dev-gh-release").write("5.6.1\n")

    Expect "found under its marker, invisible under the default, and a stale marker never matches"
    store.tree(key(base: "~/.dev/engines/ue", version: "5.6.1", marker: ".dev-gh-release")) == legacy
    store.tree(key(base: "~/.dev/engines/ue", version: "5.6.1")).nil?
    store.tree(key(base: "~/.dev/engines/ue", version: "5.6.2", marker: ".dev-gh-release")).nil?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a platform-keyed tree lives under a platform segment, apart from other platforms' builds" do
    Given "a store"
    root = Dir.mktmpdir("local-store-")
    store = Dev::Deps::LocalStore.new(data_root: root)

    Expect "the platform between base and version"
    store.tree_path(key(base: "~/.dev/ruby", version: "4.0.6", platform: "linux-x86_64")) ==
      Pathname(root) / "ruby/linux-x86_64/4.0.6"
    store.tree_path(key(base: "~/.dev/ruby", version: "4.0.6", platform: "darwin-arm64")) ==
      Pathname(root) / "ruby/darwin-arm64/4.0.6"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "tree_versions lists published versions only; remove_orphan_staging sweeps abandoned staging" do
    Given "a base with two published versions, an orphan staging dir and a stray file"
    root = Dir.mktmpdir("local-store-")
    store = Dev::Deps::LocalStore.new(data_root: root)
    base = Pathname(root) / "engines/ue"
    %w[5.6.1 5.6.2].each do |version|
      store.publish_tree(key(base: "~/.dev/engines/ue", version:)) { |staging| staging }
    end
    (base / ".staging-123-abcd").mkpath
    (base / "notes.txt").write("x")

    When "sweeping"
    removed = store.remove_orphan_staging("~/.dev/engines/ue")

    Then "versions are the published dirs; the orphan is gone, the file untouched"
    store.tree_versions("~/.dev/engines/ue").sort == ["5.6.1", "5.6.2"]
    removed == [base / ".staging-123-abcd"]
    !(base / ".staging-123-abcd").exist?
    (base / "notes.txt").exist?
    store.tree_versions("~/.dev/engines/nope") == []

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "remove_tree deletes one version and leaves its siblings" do
    Given "two published versions"
    root = Dir.mktmpdir("local-store-")
    store = Dev::Deps::LocalStore.new(data_root: root)
    %w[5.6.1 5.6.2].each do |version|
      store.publish_tree(key(base: "~/.dev/engines/ue", version:)) { |staging| staging }
    end

    When "removing one"
    store.remove_tree(key(base: "~/.dev/engines/ue", version: "5.6.1"))

    Then
    store.tree_versions("~/.dev/engines/ue") == ["5.6.2"]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "blobs: put_blob takes ownership of the file, blob finds it under the data root's cache" do
    Given "a store and a downloaded file"
    root = Dir.mktmpdir("local-store-")
    store = Dev::Deps::LocalStore.new(data_root: root)
    download = Pathname(root) / "download.zip"
    download.write("zip bytes")
    blob_key = "ficsit/SML-3.12.0-LinuxServer-abc.zip"

    When "storing it"
    File.open(download, "rb") { |file| store.put_blob(blob_key, file) }

    Then "the blob is addressable, the source is gone, a missing key is nil"
    store.blob(blob_key) == Pathname(root) / "cache" / blob_key
    store.blob(blob_key).read == "zip bytes"
    store.blob_path("ficsit/missing.zip") == Pathname(root) / "cache/ficsit/missing.zip"
    store.blob("ficsit/missing.zip").nil?
    !download.exist?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "the default store resolves its root the way every dev-managed path does" do
    Given "no explicit root"
    store = Dev::Deps::LocalStore.new

    Expect "the data root resolution, not a hardcoded home"
    store.blob_path("x") == Pathname(Dev::DataRoot.path) / "cache/x"
  end

  private

  def key(base:, version:, marker: Dev::Deps::TreeKey::DEFAULT_MARKER, platform: nil)
    Dev::Deps::TreeKey.new(base:, version:, marker:, platform:)
  end
end
