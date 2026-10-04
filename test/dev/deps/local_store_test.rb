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

  test "publish_tree refuses a directory outside staging and leaves it alone" do
    Given "a store and a directory that is not staging"
    root = Dir.mktmpdir("local-store-")
    store = Dev::Deps::LocalStore.new(data_root: root)
    elsewhere = Pathname(root) / "elsewhere"
    elsewhere.mkpath
    (elsewhere / "payload").write("x")

    When "the block hands back that directory"
    store.publish_tree(key(base: "~/.dev/engines/ue", version: "5.6.1")) { |_staging| elsewhere }

    Then "the publish is refused; the directory is untouched and nothing was published"
    raises Dev::Deps::ArtifactStore::PublishOutsideStagingError
    (elsewhere / "payload").read == "x"
    store.tree_versions("~/.dev/engines/ue") == []

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

  test "build_tree yields the final path for a build that bakes its destination, and the marker lands last" do
    Given "a store and a platform-keyed ruby key"
    root = Dir.mktmpdir("local-store-")
    store = Dev::Deps::LocalStore.new(data_root: root)
    tree_key = key(base: "~/.dev/ruby", version: "4.0.6", platform: "linux-x86_64", marker: ".dev-ruby")
    seen_during_build = nil

    When "building in place"
    published = store.build_tree(tree_key) do |dir|
      seen_during_build = store.tree(tree_key)
      (dir / "bin").mkpath
      (dir / "bin" / "ruby").write("#!/bin/sh\n")
    end

    Then "the block built straight into the tree's final path, unpublished until it returned"
    published == Pathname(root) / "ruby/linux-x86_64/4.0.6"
    seen_during_build.nil?
    store.tree(tree_key) == published
    (published / ".dev-ruby").read == "4.0.6"
    (published / "bin" / "ruby").file?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "build_tree starts clean: a half-built, markerless tree from an earlier failure is removed first" do
    Given "a markerless leftover at the tree's path"
    root = Dir.mktmpdir("local-store-")
    store = Dev::Deps::LocalStore.new(data_root: root)
    tree_key = key(base: "~/.dev/ruby", version: "4.0.6", platform: "linux-x86_64")
    leftover = store.tree_path(tree_key)
    leftover.mkpath
    (leftover / "stale").write("x")

    When "building again"
    store.build_tree(tree_key) { |dir| (dir / "fresh").write("y") }

    Then "only the new build is there"
    !(leftover / "stale").exist?
    (leftover / "fresh").file?
    store.tree(tree_key) == leftover

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "build_tree leaves no marker when the block raises, so the tree reads as unpublished" do
    Given "a store"
    root = Dir.mktmpdir("local-store-")
    store = Dev::Deps::LocalStore.new(data_root: root)
    tree_key = key(base: "~/.dev/ruby", version: "4.0.6", platform: "linux-x86_64")

    When "the build fails"
    begin
      store.build_tree(tree_key) { |dir| (dir / "partial").write("z"); raise "compiler exploded" }
    rescue RuntimeError
      nil
    end

    Then
    store.tree(tree_key).nil?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "build_tree is a no-op when the version is already published" do
    Given "a published tree"
    root = Dir.mktmpdir("local-store-")
    store = Dev::Deps::LocalStore.new(data_root: root)
    tree_key = key(base: "~/.dev/ruby", version: "4.0.6", platform: "linux-x86_64")
    store.build_tree(tree_key) { |dir| (dir / "first").write("1") }
    built_again = false

    When "building the same key"
    store.build_tree(tree_key) { |_dir| built_again = true }

    Then "the block never ran and the first build stands"
    !built_again
    (store.tree(tree_key) / "first").file?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "workdir is a platform-keyed directory the caller mutates in place: created on first use, kept after" do
    Given "a store"
    root = Dir.mktmpdir("local-store-")
    store = Dev::Deps::LocalStore.new(data_root: root)
    tree_key = key(base: "~/.dev/gems", version: "4.0.6", platform: "linux-x86_64")

    When "asking for the workdir twice, writing in between"
    first = store.workdir(tree_key)
    (first / "gems").mkpath
    second = store.workdir(tree_key)

    Then "one directory, under the platform segment, with its contents intact"
    first == Pathname(root) / "gems/linux-x86_64/4.0.6"
    second == first
    (second / "gems").directory?
    store.tree(tree_key).nil?

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
