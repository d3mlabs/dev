# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/skills"
require "fileutils"
require "pathname"
require "stringio"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Skills::AccessorTest < Minitest::Test
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

  def build_materializer(dir)
    Dev::Skills::Materializer.new(
      installer_factory: ->(root) { Dev::Skills::Installer.new(skills_dir: root, tmpdir: File.join(dir, "tmp")) },
    )
  end

  test "sync materializes every channel and reports a count per channel" do
    Given "two channels"
    dir = Dir.mktmpdir("dev-skills-accessor-test-")
    one = build_skill(dir, "corpus", "one")
    two = build_skill(dir, "gems", "rspock-3.0.0", "skills", "rspock")
    channels = [
      ListChannel.new(name: "dev", root: File.join(dir, "global"),
        entries: [Dev::Skills::Entry.new(link_name: "dev-one", source: one)]),
      ListChannel.new(name: "gem", root: File.join(dir, "project"),
        entries: [Dev::Skills::Entry.new(link_name: "gem-rspock--rspock", source: two, package: "rspock", version: "3.0.0")]),
    ]
    accessor = Dev::Skills::Accessor.new(channels: channels, materializer: build_materializer(dir))
    out = StringIO.new

    When "syncing"
    accessor.sync(out: out)

    Then "both links exist and each channel is reported"
    File.symlink?(File.join(dir, "global", "dev-one"))
    File.symlink?(File.join(dir, "project", "gem-rspock--rspock"))
    out.string == "dev: dev skills: 1 materialized under #{dir}/global.\n" \
      "dev: gem skills: 1 materialized under #{dir}/project.\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status lists each channel's links with provenance, flagging stale ones" do
    Given "a materialized gem channel with one stale link, and an empty own channel"
    dir = Dir.mktmpdir("dev-skills-accessor-test-")
    source = build_skill(dir, "gems", "rspock-3.0.0", "skills", "rspock")
    project = File.join(dir, "project")
    FileUtils.mkdir_p(project)
    File.symlink(source, File.join(project, "gem-rspock--rspock"))
    File.symlink(File.join(dir, "gems", "old-1.0.0", "skills", "old"), File.join(project, "gem-old--old"))
    channels = [
      ListChannel.new(name: "dev", root: File.join(dir, "global"), entries: []),
      ListChannel.new(name: "gem", root: project,
        entries: [Dev::Skills::Entry.new(link_name: "gem-rspock--rspock", source: source, package: "rspock", version: "3.0.0")]),
    ]
    accessor = Dev::Skills::Accessor.new(channels: channels, materializer: build_materializer(dir))
    out = StringIO.new

    When "asking for status"
    accessor.status(out: out)

    Then "the report groups by channel, names the package/version, and flags the stale link"
    out.string == <<~OUT
      dev: dev skills: 0 linked under #{dir}/global
      dev: gem skills: 2 linked under #{project}
        gem-old--old  (stale — not declared; run `dev skills sync`)  -> #{dir}/gems/old-1.0.0/skills/old
        gem-rspock--rspock  [rspock 3.0.0]  -> #{source}
    OUT

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
