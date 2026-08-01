# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/learnings"
require "dev/settings"
require "dev/skill_installer"
require "pathname"
require "tmpdir"
require "fileutils"
require "stringio"

# A gem skill linker stand-in: the learnings surface is under test here, and
# the real linker would shell out to bundler.
class RecordingGemSkillLinker
  attr_reader :link_all_calls

  def initialize
    @link_all_calls = 0
  end

  def link_all
    @link_all_calls += 1
  end
end unless defined?(RecordingGemSkillLinker)

transform!(RSpock::AST::Transformation)
class Dev::Learnings::AccessorTest < Minitest::Test
  # A real git source repo plus a fully tmpdir-scoped accessor (nothing
  # touches the real user config, cache, or skills). Returns the accessor and
  # the pieces we assert on.
  def build_env(dir, project_root: :default)
    source = build_source_repo(dir)
    config = File.join(dir, "config.yml")
    File.write(config, "knowledge_repo: #{source}\n")
    settings = Dev::Settings.new(config_path: config)
    cache = Dev::Learnings::Cache.new(repo: source, dir: File.join(dir, "cache"))
    installer = Dev::SkillInstaller.new(skills_dir: File.join(dir, "user-skills"))
    synchronizer = Dev::Learnings::Synchronizer.new(settings: settings, cache: cache, skill_installer: installer)
    project = project_root == :default ? Pathname(dir) / "repo" : project_root
    FileUtils.mkdir_p(project) if project
    gem_skill_linker = project && RecordingGemSkillLinker.new
    accessor = Dev::Learnings::Accessor.new(
      project_root: project, settings: settings, cache: cache, synchronizer: synchronizer,
      skill_installer: installer, gem_skill_linker: gem_skill_linker,
    )
    [accessor, cache, project, synchronizer, gem_skill_linker]
  end

  def build_source_repo(dir)
    source = File.join(dir, "knowledge")
    FileUtils.mkdir_p(File.join(source, "skills", "srp"))
    File.write(File.join(source, "skills", "srp", "SKILL.md"), "# srp\n")
    File.write(File.join(source, "index.md"), "## Invariants (always-on)\n\n- [design/srp] One reason.\n")
    system("git", "-C", source, "init", "-q", exception: true)
    system("git", "-C", source, "add", ".", exception: true)
    system("git", "-C", source, "-c", "user.email=dev@test", "-c", "user.name=dev",
      "commit", "-qm", "seed", exception: true)
    source
  end

  test "learnings sync refreshes the whole read path and reports" do
    Given "a configured accessor with no cache yet"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    accessor, cache, project, synchronizer, gem_skill_linker = build_env(dir)
    out = StringIO.new

    When "running dev learnings sync"
    accessor.run(["sync"], out: out)

    Then "cache cloned, org skill linked, invariants rendered + linked, gem skills relinked, and reported"
    cache.present?
    File.symlink?(File.join(dir, "user-skills", "srp"))
    synchronizer.rendered_invariants_file.file?
    (project / ".cursor" / "rules" / "org-invariants.mdc").symlink?
    gem_skill_linker.link_all_calls == 1
    out.string.include?("learnings synced")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "learnings sync outside a project does the machine-global parts and says what it skipped" do
    Given "a configured accessor with no enclosing project"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    accessor, cache, _project, synchronizer, = build_env(dir, project_root: nil)
    out = StringIO.new

    When "running dev learnings sync"
    accessor.run(["sync"], out: out)

    Then "cache and machine-side render exist; the project-scoped parts were skipped"
    cache.present?
    synchronizer.rendered_invariants_file.file?
    out.string.include?("no enclosing project")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status reports a missing configuration with instructions" do
    Given "an accessor over empty settings"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    saved_env = ENV.delete("DEV_KNOWLEDGE_REPO")
    accessor = Dev::Learnings::Accessor.new(
      project_root: dir, settings: Dev::Settings.new(config_path: File.join(dir, "config.yml")),
    )
    out = StringIO.new

    When "running dev learnings status"
    accessor.run(["status"], out: out)

    Then "the message names the setting and the ENV override"
    out.string.include?("knowledge_repo:")
    out.string.include?("DEV_KNOWLEDGE_REPO")

    Cleanup
    ENV["DEV_KNOWLEDGE_REPO"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "status before the first clone points at dev learnings sync" do
    Given "a configured accessor with no cache yet"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    accessor, = build_env(dir)
    out = StringIO.new

    When "running dev learnings status"
    accessor.run(["status"], out: out)

    Then
    out.string.include?("not cloned yet")
    out.string.include?("dev learnings sync")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status after a sync reports each tier's rendered/linked artifacts" do
    Given "a fully synced read path"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    accessor, = build_env(dir)
    accessor.run(["sync"], out: StringIO.new)
    out = StringIO.new

    When "running dev learnings status"
    accessor.run(["status"], out: out)

    Then "cache age, the machine-side render, the org skill links, and the project link are all reported"
    out.string.include?("refreshed")
    out.string.include?("ago")
    out.string.include?("invariants: rendered at")
    out.string.include?("org skills: 1 linked")
    out.string.include?("project invariants link:")
    out.string.include?("(linked)")
    out.string.include?("gem skills: 0 linked")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status without a project reports the machine tiers and says the project is absent" do
    Given "a synced accessor with no enclosing project"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    accessor, = build_env(dir, project_root: nil)
    accessor.run(["sync"], out: StringIO.new)
    out = StringIO.new

    When "running dev learnings status"
    accessor.run(["status"], out: out)

    Then
    out.string.include?("invariants: rendered at")
    out.string.include?("project: none")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "invariants prints the Tier-0 prompt block" do
    Given "a synced cache"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    accessor, cache, = build_env(dir)
    cache.refresh
    out = StringIO.new

    When "running dev learnings invariants"
    accessor.run(["invariants"], out: out)

    Then "the block carries the invariant lines and the skill-pointer note, no mdc framing"
    out.string.include?("[design/srp]")
    out.string.include?("on-demand skill")
    !out.string.include?("alwaysApply")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "invariants raises when no knowledge repo is configured" do
    Given "an accessor over empty settings"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    saved_env = ENV.delete("DEV_KNOWLEDGE_REPO")
    accessor = Dev::Learnings::Accessor.new(
      project_root: dir, settings: Dev::Settings.new(config_path: File.join(dir, "config.yml")),
    )

    When "running dev learnings invariants"
    accessor.run(["invariants"], out: StringIO.new)

    Then
    raises Dev::Learnings::Accessor::InvariantsUnavailableError

    Cleanup
    ENV["DEV_KNOWLEDGE_REPO"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "invariants raises before the first clone" do
    Given "a configured accessor with no cache yet"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    accessor, = build_env(dir)

    When "running dev learnings invariants"
    accessor.run(["invariants"], out: StringIO.new)

    Then
    raises Dev::Learnings::Accessor::InvariantsUnavailableError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "invariants raises when the index has no invariants section" do
    Given "a synced cache whose index carries no invariants section"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    accessor, cache, = build_env(dir)
    cache.refresh
    cache.index_file.write("# Org learnings index\n\n## Knowledge (on-demand)\n\n- a line\n")

    When "running dev learnings invariants"
    accessor.run(["invariants"], out: StringIO.new)

    Then
    raises Dev::Learnings::Accessor::InvariantsUnavailableError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an unrecognized invocation is rejected with usage" do
    Given "a configured accessor"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    accessor, = build_env(dir)

    When "running an unknown subcommand"
    accessor.run(["bogus"], out: StringIO.new)

    Then
    raises Dev::Learnings::Accessor::UsageError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "extra arguments to a subcommand are rejected with usage" do
    Given "a configured accessor"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    accessor, = build_env(dir)

    When "running sync with a stray argument"
    accessor.run(["sync", "extra"], out: StringIO.new)

    Then
    raises Dev::Learnings::Accessor::UsageError

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
