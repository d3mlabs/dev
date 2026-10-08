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
class Dev::Skills::AccessorTest < Minitest::Test
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

  def build_materializer(dir)
    Dev::Skills::Materializer.new(
      installer_factory: ->(root) { Dev::Skills::Installer.new(skills_dir: root, tmpdir: File.join(dir, "tmp")) },
    )
  end

  def entry(name, source, **extra) = Dev::Skills::Entry.new(link_name: name, source: source, **extra)

  # own (user-global) + gem (project-scoped) channels over fixture trees.
  def build_channels(dir)
    one = build_skill(dir, "shipped", "one")
    rspock = build_skill(dir, "gems", "rspock-3.0.0", "skills", "rspock")
    [
      ListChannel.new(name: "dev", root: File.join(dir, "global"), entries: [entry("one", one)]),
      ListChannel.new(name: "gem", root: File.join(dir, "project"), project_scoped: true,
        entries: [entry("gem/rspock/rspock", rspock, package: "rspock", version: "3.0.0")]),
    ]
  end

  test "sync materializes every channel and reports a count per channel" do
    Given "two channels"
    dir = Dir.mktmpdir("dev-skills-accessor-test-")
    accessor = Dev::Skills::Accessor.new(channels: build_channels(dir), materializer: build_materializer(dir))
    out = StringIO.new

    When "syncing"
    accessor.sync(out: out)

    Then "both links exist and each channel is reported"
    File.symlink?(File.join(dir, "global", "one"))
    File.symlink?(File.join(dir, "project", "gem", "rspock", "rspock"))
    out.string == "dev: dev skills: 1 materialized under #{dir}/global.\n" \
      "dev: gem skills: 1 materialized under #{dir}/project.\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "sync inside a project sweeps the legacy flat gem links first" do
    Given "a project carrying a pre-#250 gem link beside the repo's own link"
    dir = Dir.mktmpdir("dev-skills-accessor-test-")
    skills = Pathname(dir) / ".agents" / "skills"
    FileUtils.mkdir_p(skills)
    File.symlink("/nowhere/rspock", skills / "gem-rspock--rspock")
    File.symlink("/nowhere/mine", skills / "mine")
    accessor = Dev::Skills::Accessor.new(channels: [], project_root: dir, materializer: build_materializer(dir))

    When "syncing"
    accessor.sync(out: StringIO.new)

    Then "the legacy link is gone, the repo's own stands"
    !File.symlink?(skills / "gem-rspock--rspock")
    File.symlink?(skills / "mine")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status lists each channel's recorded links with provenance, flagging ones that no longer stand" do
    Given "synced channels, with the gem link then removed by hand"
    dir = Dir.mktmpdir("dev-skills-accessor-test-")
    channels = build_channels(dir)
    materializer = build_materializer(dir)
    materializer.sync(channels)
    FileUtils.rm_f(File.join(dir, "project", "gem", "rspock", "rspock"))
    accessor = Dev::Skills::Accessor.new(channels: channels, materializer: materializer)
    out = StringIO.new

    When "asking for status"
    accessor.status(out: out)

    Then "the report groups by channel, names the package/version, and flags the missing link"
    out.string == <<~OUT
      dev: dev skills: 1 linked under #{dir}/global
        one  -> #{dir}/shipped/one
      dev: gem skills: 1 linked under #{dir}/project
        gem/rspock/rspock  [rspock 3.0.0]  -> #{dir}/gems/rspock-3.0.0/skills/rspock  (missing — run `dev skills sync`)
    OUT

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status lists same-named skills across channels as plain information" do
    Given "two packages in two channels shipping a skill with the same name, plus an org skill of that name"
    dir = Dir.mktmpdir("dev-skills-accessor-test-")
    a = build_skill(dir, "gems", "a-1.2.0", "skills", "tdd")
    b = build_skill(dir, "pips", "b-0.9.1", "skills", "tdd")
    org = build_skill(dir, "cache", "tdd")
    channels = [
      ListChannel.new(name: "org", root: File.join(dir, "global"), entries: [entry("tdd", org)]),
      ListChannel.new(name: "gem", root: File.join(dir, "project"), project_scoped: true,
        entries: [entry("gem/a/tdd", a, package: "a", version: "1.2.0")]),
      ListChannel.new(name: "pip", root: File.join(dir, "project"), project_scoped: true,
        entries: [entry("pip/b/tdd", b, package: "b", version: "0.9.1")]),
    ]
    materializer = build_materializer(dir)
    materializer.sync(channels)
    accessor = Dev::Skills::Accessor.new(channels: channels, materializer: materializer)
    out = StringIO.new

    When "asking for status"
    accessor.status(out: out)

    Then "a trailing section lists the group with each origin"
    out.string.end_with?(<<~OUT)
      dev: same-named skills (all load; the agent sees each by path):
        tdd ← org, gem/a 1.2.0, pip/b 0.9.1
    OUT

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status --json emits the manifests per channel with presence" do
    Given "synced channels"
    dir = Dir.mktmpdir("dev-skills-accessor-test-")
    channels = build_channels(dir)
    materializer = build_materializer(dir)
    materializer.sync(channels)
    accessor = Dev::Skills::Accessor.new(channels: channels, materializer: materializer)
    out = StringIO.new

    When "asking for JSON status"
    accessor.status(out: out, json: true)

    Then "the document carries each channel's root and records"
    JSON.parse(out.string) == {
      "channels" => [
        { "name" => "dev", "root" => "#{dir}/global", "skills" => [
          { "name" => "one", "integration" => "dev", "package" => nil, "version" => nil,
            "link" => "one", "source" => "#{dir}/shipped/one", "present" => true },
        ] },
        { "name" => "gem", "root" => "#{dir}/project", "skills" => [
          { "name" => "rspock", "integration" => "gem", "package" => "rspock", "version" => "3.0.0",
            "link" => "gem/rspock/rspock", "source" => "#{dir}/gems/rspock-3.0.0/skills/rspock", "present" => true },
        ] },
      ],
    }

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
