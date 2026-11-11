# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/skills"
require "fileutils"
require "json"
require "pathname"
require "stringio"
require "support/recording_ui"
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

    def project_scoped?
      @project_scoped
    end
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

  def entry(name, source, **extra)
    Dev::Skills::Entry.new(link_name: name, source: source, **extra)
  end

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
    ui = RecordingUi.new
    accessor = Dev::Skills::Accessor.new(channels: build_channels(dir), ui: ui, materializer: build_materializer(dir))

    When "syncing"
    accessor.sync

    Then "both links exist; one frame, a spin per channel materialized, then a count per channel"
    File.symlink?(File.join(dir, "global", "one"))
    File.symlink?(File.join(dir, "project", "gem", "rspock", "rspock"))
    ui.rows == [
      [:frame, "Syncing skill channels", 0],
      [:spin, "Materializing dev skills under #{dir}/global", 1],
      [:spin, "Materializing gem skills under #{dir}/project", 1],
      [:note, "{{v}} dev skills: 1 materialized under #{dir}/global.", 1],
      [:note, "{{v}} gem skills: 1 materialized under #{dir}/project.", 1],
    ]

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
    accessor = Dev::Skills::Accessor.new(
      channels: [], ui: RecordingUi.new, project_root: dir, materializer: build_materializer(dir),
    )

    When "syncing"
    accessor.sync

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
    ui = RecordingUi.new
    accessor = Dev::Skills::Accessor.new(channels: channels, ui: ui, materializer: materializer)

    When "asking for status"
    accessor.status

    Then "a frame per channel; each link a fact naming the package/version, the missing one a {{x}} with the remedy"
    ui.rows == [
      [:frame, "dev skills (1 linked under #{dir}/global)", 0],
      [:note, "{{v}} one  -> #{dir}/shipped/one", 1],
      [:frame, "gem skills (1 linked under #{dir}/project)", 0],
      [:note, "{{x}} gem/rspock/rspock  [rspock 3.0.0]  -> #{dir}/gems/rspock-3.0.0/skills/rspock  " \
        "(missing — run `dev skills sync`)", 1],
    ]

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
    ui = RecordingUi.new
    accessor = Dev::Skills::Accessor.new(channels: channels, ui: ui, materializer: materializer)

    When "asking for status"
    accessor.status

    Then "a trailing frame lists the group with each origin"
    ui.rows.last(2) == [
      [:frame, "Same-named skills (all load; the agent sees each by path)", 0],
      [:note, "tdd ← org, gem/a 1.2.0, pip/b 0.9.1", 1],
    ]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status warns when a project-scoped root is not gitignored, and is silent once it is" do
    Given "a git repo whose project-scoped channel root is not ignored, and the same repo once it is"
    dir = Dir.mktmpdir("dev-skills-accessor-test-")
    repo = Pathname(dir) / "repo"
    FileUtils.mkdir_p(repo)
    system("git", "-C", repo.to_s, "init", "-q", exception: true)
    gem = ListChannel.new(name: "gem", root: repo / ".agents" / "skills" / "dev", project_scoped: true, entries: [])
    before = RecordingUi.new
    after = RecordingUi.new
    build = lambda do |ui|
      Dev::Skills::Accessor.new(channels: [gem], ui: ui, project_root: repo, materializer: build_materializer(dir))
    end

    When "asking for status before and after adding the ignore line"
    build.call(before).status
    (repo / ".gitignore").write(".agents/skills/dev/\n")
    build.call(after).status

    Then "the warning is a bare {{x}} note after the channel frames, naming the root and the repair; then it is gone"
    before.rows.last == [:note, "{{x}} .agents/skills/dev/ is not gitignored — run `dev learnings init --gitignore`.", 0]
    after.rows.none? { |_kind, text, _depth| text.include?("not gitignored") }

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status --json emits the manifests per channel with presence" do
    Given "synced channels"
    dir = Dir.mktmpdir("dev-skills-accessor-test-")
    channels = build_channels(dir)
    materializer = build_materializer(dir)
    materializer.sync(channels)
    ui = RecordingUi.new
    accessor = Dev::Skills::Accessor.new(channels: channels, ui: ui, materializer: materializer)
    out = StringIO.new

    When "asking for JSON status"
    accessor.status_json(out: out)

    Then "the document carries each channel's root and records, bare — the Ui is never spoken to"
    ui.rows == []
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
