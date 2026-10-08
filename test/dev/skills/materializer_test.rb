# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/skills"
require "fileutils"
require "json"
require "pathname"
require "stringio"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Skills::MaterializerTest < Minitest::Test
  # A channel whose entries are given up front.
  class ListChannel
    include Dev::Skills::Channel
    attr_reader :name, :root, :entries

    def initialize(name:, root:, entries:, project_scoped: false)
      @name = name
      @root = Pathname(root)
      @entries = entries
      @project_scoped = project_scoped
    end

    def project_scoped? = @project_scoped
  end

  def build_skill(dir, *path_parts)
    source = Pathname(dir).join(*path_parts)
    FileUtils.mkdir_p(source)
    File.write(source / "SKILL.md", "# skill\n")
    source
  end

  def entry(name, source, **extra) = Dev::Skills::Entry.new(link_name: name, source: source, **extra)

  # The fixture trees live under the real temp dir, so the installer's
  # ephemeral-source guard is pinned inside the fixture dir.
  def build_materializer(dir)
    Dev::Skills::Materializer.new(
      installer_factory: ->(root) { Dev::Skills::Installer.new(skills_dir: root, tmpdir: File.join(dir, "tmp")) },
    )
  end

  def manifest_links(root) = JSON.parse(File.read(File.join(root, "manifest.json"))).fetch("skills").map { |s| s["link"] }

  test "sync links every entry of every channel into that channel's root, nested names included" do
    Given "two channels with different roots, one using nested link names"
    dir = Dir.mktmpdir("dev-materializer-test-")
    a_source = build_skill(dir, "corpus-a", "one")
    b_source = build_skill(dir, "gems", "rspock-3.0.0", "skills", "rspock")
    a = ListChannel.new(name: "a", root: File.join(dir, "root-a"), entries: [entry("one", a_source)])
    b = ListChannel.new(name: "gem", root: File.join(dir, "root-b"), entries: [entry("gem/rspock/rspock", b_source)])

    When "syncing both"
    build_materializer(dir).sync([a, b])

    Then "each link lands in its own channel's root"
    File.readlink(File.join(dir, "root-a", "one")) == a_source.to_s
    File.readlink(File.join(dir, "root-b", "gem", "rspock", "rspock")) == b_source.to_s

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "sync writes a manifest per root recording each channel's links with provenance" do
    Given "two channels sharing one root"
    dir = Dir.mktmpdir("dev-materializer-test-")
    root = File.join(dir, "root")
    own = build_skill(dir, "shipped", "ai-flow")
    org = build_skill(dir, "cache", "typed-errors")
    a = ListChannel.new(name: "dev", root: root, entries: [entry("ai-flow", own)])
    b = ListChannel.new(name: "org", root: root, entries: [entry("typed-errors", org, package: "knowledge", version: "abc")])

    When "syncing both"
    build_materializer(dir).sync([a, b])

    Then "one manifest holds both channels' records, each with its source and provenance"
    manifest = JSON.parse(File.read(File.join(root, "manifest.json")))
    manifest["schema"] == 1
    manifest["root"] == root
    manifest["skills"] == [
      { "name" => "ai-flow", "integration" => "dev", "package" => nil, "version" => nil,
        "link" => "ai-flow", "source" => own.to_s },
      { "name" => "typed-errors", "integration" => "org", "package" => "knowledge", "version" => "abc",
        "link" => "typed-errors", "source" => org.to_s },
    ]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "sync prunes exactly what the manifest recorded for the channel and it no longer declares" do
    Given "a channel that shrank, beside another channel's link and a foreign link in the same root"
    dir = Dir.mktmpdir("dev-materializer-test-")
    root = File.join(dir, "root")
    kept = build_skill(dir, "corpus", "kept")
    gone = build_skill(dir, "corpus", "gone")
    theirs = build_skill(dir, "other", "theirs")
    materializer = build_materializer(dir)
    materializer.sync([
      ListChannel.new(name: "a", root: root, entries: [entry("a/kept", kept), entry("a/gone", gone)]),
      ListChannel.new(name: "b", root: root, entries: [entry("b/theirs", theirs)]),
    ])
    File.symlink(File.join(dir, "nowhere"), File.join(root, "mine"))

    When "syncing the shrunken channel alone"
    materializer.sync([ListChannel.new(name: "a", root: root, entries: [entry("a/kept", kept)])])

    Then "only the channel's undeclared link is gone (and its emptied dir); b's and the foreign link stand"
    File.symlink?(File.join(root, "a", "kept"))
    !File.symlink?(File.join(root, "a", "gone"))
    File.symlink?(File.join(root, "b", "theirs"))
    File.symlink?(File.join(root, "mine"))
    manifest_links(root) == ["a/kept", "b/theirs"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "sync removes the emptied package dir when a package's last skill is pruned" do
    Given "a package whose only skill then leaves the channel"
    dir = Dir.mktmpdir("dev-materializer-test-")
    root = File.join(dir, "root")
    skill = build_skill(dir, "gems", "old-1.0.0", "skills", "old")
    materializer = build_materializer(dir)
    materializer.sync([ListChannel.new(name: "gem", root: root, entries: [entry("gem/old/old", skill)])])

    When "syncing with the package gone"
    materializer.sync([ListChannel.new(name: "gem", root: root, entries: [])])

    Then "the package and integration dirs are gone; the root stays"
    !File.exist?(File.join(root, "gem"))
    File.directory?(root)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "sync never touches a link it has no record of, even under the channel's own prefix" do
    Given "a link someone placed under the channel's integration dir before any manifest existed"
    dir = Dir.mktmpdir("dev-materializer-test-")
    root = File.join(dir, "root")
    FileUtils.mkdir_p(File.join(root, "gem", "handmade"))
    File.symlink(File.join(dir, "elsewhere"), File.join(root, "gem", "handmade", "thing"))
    skill = build_skill(dir, "gems", "rspock-3.0.0", "skills", "rspock")

    When "syncing a channel that does not declare it"
    build_materializer(dir).sync([ListChannel.new(name: "gem", root: root, entries: [entry("gem/rspock/rspock", skill)])])

    Then "the unrecorded link survives and is not in the manifest"
    File.symlink?(File.join(root, "gem", "handmade", "thing"))
    manifest_links(root) == ["gem/rspock/rspock"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "sync keeps a durable link whose entry now resolves under the temp dir, recording the durable target" do
    Given "a link minted from a durable source, then the same entry pointing at an ephemeral copy"
    dir = Dir.mktmpdir("dev-materializer-test-")
    root = File.join(dir, "root")
    durable = build_skill(dir, "corpus", "skill")
    ephemeral = build_skill(dir, "tmp", "corpus", "skill")
    materializer = build_materializer(dir)
    materializer.sync([ListChannel.new(name: "a", root: root, entries: [entry("skill", durable)])])
    old_stderr = $stderr
    $stderr = StringIO.new

    When "syncing the ephemeral resolution"
    materializer.sync([ListChannel.new(name: "a", root: root, entries: [entry("skill", ephemeral)])])

    Then "the durable link survives (declared, so not pruned; refused, so not re-pointed) and is what's recorded"
    File.readlink(File.join(root, "skill")) == durable.to_s
    JSON.parse(File.read(File.join(root, "manifest.json"))).fetch("skills")[0]["source"] == durable.to_s

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(dir)
  end

  test "sync does not record an entry it could not link" do
    Given "an entry whose only source is ephemeral and no prior link"
    dir = Dir.mktmpdir("dev-materializer-test-")
    root = File.join(dir, "root")
    ephemeral = build_skill(dir, "tmp", "corpus", "skill")
    old_stderr = $stderr
    $stderr = StringIO.new

    When "syncing"
    build_materializer(dir).sync([ListChannel.new(name: "a", root: root, entries: [entry("skill", ephemeral)])])

    Then "the manifest is written but empty"
    manifest_links(root) == []

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(dir)
  end

  test "sync makes a project-scoped root ignore itself, once, and leaves a user-global root alone" do
    Given "a project-scoped channel and a user-global one"
    dir = Dir.mktmpdir("dev-materializer-test-")
    skill = build_skill(dir, "corpus", "skill")
    project = ListChannel.new(name: "gem", root: File.join(dir, "project"), entries: [entry("gem/p/skill", skill)], project_scoped: true)
    global = ListChannel.new(name: "dev", root: File.join(dir, "global"), entries: [entry("skill", skill)])
    materializer = build_materializer(dir)

    When "syncing both, then editing the self-ignore and syncing again"
    materializer.sync([project, global])
    File.write(File.join(dir, "project", ".gitignore"), "*\n!keep-me\n")
    materializer.sync([project])

    Then "the project root carries `*`, the edit is kept, the global root has no ignore file"
    File.read(File.join(dir, "project", ".gitignore")) == "*\n!keep-me\n"
    !File.exist?(File.join(dir, "global", ".gitignore"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "sync starts over from an empty record when the manifest is corrupt" do
    Given "a root whose manifest is not JSON"
    dir = Dir.mktmpdir("dev-materializer-test-")
    root = File.join(dir, "root")
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "manifest.json"), "{not json")
    skill = build_skill(dir, "corpus", "skill")

    When "syncing"
    build_materializer(dir).sync([ListChannel.new(name: "a", root: root, entries: [entry("skill", skill)])])

    Then "the link is placed and the manifest rewritten"
    File.symlink?(File.join(root, "skill"))
    manifest_links(root) == ["skill"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "sync reports a failing channel as a warning and still materializes the others" do
    Given "a channel whose entries raise, followed by a healthy one"
    dir = Dir.mktmpdir("dev-materializer-test-")
    source = build_skill(dir, "corpus", "ok")
    broken = ListChannel.new(name: "x", root: File.join(dir, "root"), entries: [])
    broken.define_singleton_method(:entries) { raise "bundler exploded" }
    healthy = ListChannel.new(name: "a", root: File.join(dir, "root"), entries: [entry("ok", source)])
    old_stderr = $stderr
    $stderr = StringIO.new

    When "syncing both"
    build_materializer(dir).sync([broken, healthy])

    Then "the failure is a warning naming the channel, and the healthy link exists"
    $stderr.string.include?("could not materialize x skills (bundler exploded)")
    File.symlink?(File.join(dir, "root", "ok"))

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(dir)
  end

  test "materialized reports the channel's recorded links and whether each still stands" do
    Given "a synced channel whose one link was then re-pointed by hand and another removed"
    dir = Dir.mktmpdir("dev-materializer-test-")
    root = File.join(dir, "root")
    a = build_skill(dir, "corpus", "a")
    b = build_skill(dir, "corpus", "b")
    c = build_skill(dir, "corpus", "c")
    channel = ListChannel.new(name: "x", root: root, entries: [entry("x/a", a, package: "p", version: "1"), entry("x/b", b), entry("x/c", c)])
    materializer = build_materializer(dir)
    materializer.sync([channel])
    FileUtils.rm_f(File.join(root, "x", "b"))
    File.symlink(File.join(dir, "elsewhere"), File.join(root, "x", "b"))
    FileUtils.rm_f(File.join(root, "x", "c"))

    When "listing what is materialized"
    links = materializer.materialized(channel)

    Then "all three records come back in link order, with presence reflecting the disk"
    links.map { |l| l.record.link } == ["x/a", "x/b", "x/c"]
    links.map(&:present) == [true, false, false]
    links[0].record.package == "p"
    links[0].record.version == "1"
    links[0].record.name == "a"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "materialized is empty when the root has no manifest" do
    Given "a channel over a root that was never synced"
    dir = Dir.mktmpdir("dev-materializer-test-")
    channel = ListChannel.new(name: "a", root: File.join(dir, "missing"), entries: [])

    Expect "no links"
    build_materializer(dir).materialized(channel) == []

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
