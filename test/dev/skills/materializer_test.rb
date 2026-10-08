# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/skills"
require "fileutils"
require "pathname"
require "stringio"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Skills::MaterializerTest < Minitest::Test
  # A channel whose entries are given up front; owns `#{name}-` prefixed links.
  class ListChannel
    include Dev::Skills::Channel
    attr_reader :name, :root, :entries

    def initialize(name:, root:, entries:)
      @name = name
      @root = Pathname(root)
      @entries = entries
    end

    def owns?(link) = link.basename.to_s.start_with?("#{@name}-")
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

  test "sync links every entry of every channel into that channel's root" do
    Given "two channels with different roots"
    dir = Dir.mktmpdir("dev-materializer-test-")
    a_source = build_skill(dir, "corpus-a", "one")
    b_source = build_skill(dir, "corpus-b", "two")
    a = ListChannel.new(name: "a", root: File.join(dir, "root-a"), entries: [entry("a-one", a_source)])
    b = ListChannel.new(name: "b", root: File.join(dir, "root-b"), entries: [entry("b-two", b_source)])

    When "syncing both"
    build_materializer(dir).sync([a, b])

    Then "each link lands in its own channel's root"
    File.readlink(File.join(dir, "root-a", "a-one")) == a_source.to_s
    File.readlink(File.join(dir, "root-b", "b-two")) == b_source.to_s

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "sync prunes a link the channel owns but no longer declares, leaving other links alone" do
    Given "a previously linked skill that left the channel, a foreign link, and another channel's link"
    dir = Dir.mktmpdir("dev-materializer-test-")
    root = File.join(dir, "root")
    kept = build_skill(dir, "corpus", "kept")
    gone = build_skill(dir, "corpus", "gone")
    channel = ListChannel.new(name: "a", root: root, entries: [entry("a-kept", kept), entry("a-gone", gone)])
    materializer = build_materializer(dir)
    materializer.sync([channel])
    other = build_skill(dir, "other", "theirs")
    File.symlink(other, File.join(root, "b-theirs"))
    File.symlink(File.join(dir, "nowhere"), File.join(root, "mine"))
    channel = ListChannel.new(name: "a", root: root, entries: [entry("a-kept", kept)])

    When "syncing with the shrunken channel"
    materializer.sync([channel])

    Then "only the channel's undeclared link is gone"
    File.symlink?(File.join(root, "a-kept"))
    !File.symlink?(File.join(root, "a-gone"))
    File.symlink?(File.join(root, "b-theirs"))
    File.symlink?(File.join(root, "mine"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "sync keeps a durable link whose entry now resolves under the temp dir" do
    Given "a link minted from a durable source, then the same entry pointing at an ephemeral copy"
    dir = Dir.mktmpdir("dev-materializer-test-")
    root = File.join(dir, "root")
    durable = build_skill(dir, "corpus", "skill")
    ephemeral = build_skill(dir, "tmp", "corpus", "skill")
    materializer = build_materializer(dir)
    materializer.sync([ListChannel.new(name: "a", root: root, entries: [entry("a-skill", durable)])])
    old_stderr = $stderr
    $stderr = StringIO.new

    When "syncing the ephemeral resolution"
    materializer.sync([ListChannel.new(name: "a", root: root, entries: [entry("a-skill", ephemeral)])])

    Then "the durable link survives (declared, so not pruned; refused, so not re-pointed)"
    File.readlink(File.join(root, "a-skill")) == durable.to_s

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(dir)
  end

  test "sync reports a failing channel as a warning and still materializes the others" do
    Given "a channel whose entries raise, followed by a healthy one"
    dir = Dir.mktmpdir("dev-materializer-test-")
    source = build_skill(dir, "corpus", "ok")
    broken = ListChannel.new(name: "x", root: File.join(dir, "root"), entries: [])
    broken.define_singleton_method(:entries) { raise "bundler exploded" }
    healthy = ListChannel.new(name: "a", root: File.join(dir, "root"), entries: [entry("a-ok", source)])
    old_stderr = $stderr
    $stderr = StringIO.new

    When "syncing both"
    build_materializer(dir).sync([broken, healthy])

    Then "the failure is a warning naming the channel, and the healthy link exists"
    $stderr.string.include?("could not materialize x skills (bundler exploded)")
    File.symlink?(File.join(dir, "root", "a-ok"))

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(dir)
  end

  test "materialized reports the channel's links with their declaring entries, stale ones with none" do
    Given "a channel with one declared link and one stale link in its root"
    dir = Dir.mktmpdir("dev-materializer-test-")
    root = File.join(dir, "root")
    source = build_skill(dir, "corpus", "skill")
    declared = entry("a-skill", source, package: "rspock", version: "3.0.0")
    FileUtils.mkdir_p(root)
    File.symlink(source, File.join(root, "a-skill"))
    File.symlink(File.join(dir, "old"), File.join(root, "a-old"))
    File.symlink(source, File.join(root, "b-theirs"))
    channel = ListChannel.new(name: "a", root: root, entries: [declared])

    When "listing what is materialized"
    links = build_materializer(dir).materialized(channel)

    Then "both owned links appear, sorted, the stale one without an entry; the foreign link does not"
    links.map { |l| l.link.basename.to_s } == ["a-old", "a-skill"]
    links[0].entry.nil?
    links[1].entry == declared
    links[1].target == source

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "materialized is empty when the root does not exist yet" do
    Given "a channel over a root that was never created"
    dir = Dir.mktmpdir("dev-materializer-test-")
    channel = ListChannel.new(name: "a", root: File.join(dir, "missing"), entries: [])

    Expect "no links"
    build_materializer(dir).materialized(channel) == []

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
