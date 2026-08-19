# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/gem_skill_linker"
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
    # The fixture cache lives under the real temp dir; the tmpdir override
    # keeps the installer's ephemeral-source guard out of these tests' way.
    installer = Dev::SkillInstaller.new(skills_dir: File.join(dir, "user-skills"), tmpdir: File.join(dir, "tmp"))
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

  # Rewind the cache's sync marker (the same files Cache#synced_at reads) so
  # status reports an older age.
  def backdate_cache(cache, seconds)
    markers = [cache.dir / ".git" / "FETCH_HEAD", cache.dir / ".git" / "HEAD"].select(&:exist?)
    FileUtils.touch(markers, mtime: Time.now - seconds)
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

  test "status with a cloned but never-synced cache points both tiers at dev learnings sync" do
    Given "a cloned cache that has never been distributed"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    accessor, cache, = build_env(dir)
    cache.refresh
    out = StringIO.new

    When "running dev learnings status"
    accessor.run(["status"], out: out)

    Then "the org render and the project link are both reported missing"
    out.string.include?("invariants: not rendered")
    out.string.include?("missing — run `dev learnings sync`")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status flags an invariants rules file that is not dev's link" do
    Given "a synced project whose rules file was replaced by a plain file"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    accessor, _cache, project, synchronizer, = build_env(dir)
    accessor.run(["sync"], out: StringIO.new)
    rules_file = synchronizer.project_rules_file(project)
    rules_file.delete
    rules_file.write("# hand-rolled, not dev's symlink\n")
    out = StringIO.new

    When "running dev learnings status"
    accessor.run(["status"], out: out)

    Then
    out.string.include?("present but not dev's link")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status counts the project's gem skill links and ignores other entries" do
    Given "a synced project with one gem skill link and one unrelated file"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    accessor, _cache, project, = build_env(dir)
    accessor.run(["sync"], out: StringIO.new)
    gem_skills_dir = project.join(*Dev::Deps::GemSkillLinker::AGENT_SKILLS_SUBDIRS)
    FileUtils.mkdir_p(gem_skills_dir)
    File.symlink(File.join(dir, "knowledge", "skills", "srp"), gem_skills_dir / "gem-rspock--rspock")
    File.write(gem_skills_dir / "README.md", "not a link\n")
    out = StringIO.new

    When "running dev learnings status"
    accessor.run(["status"], out: out)

    Then
    out.string.include?("gem skills: 1 linked")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status formats the cache age in minutes, hours, and days" do
    Given "a synced accessor"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    accessor, cache, = build_env(dir)
    accessor.run(["sync"], out: StringIO.new)

    When "running status with the cache's sync marker backdated to each granularity"
    reports = { 5 * 60 => StringIO.new, 3 * 3600 => StringIO.new, 2 * 86_400 => StringIO.new }
    reports.each do |age_seconds, out|
      backdate_cache(cache, age_seconds)
      accessor.run(["status"], out: out)
    end

    Then "each report carries the compact age"
    reports[5 * 60].string.include?("(refreshed 5m ago)")
    reports[3 * 3600].string.include?("(refreshed 3h ago)")
    reports[2 * 86_400].string.include?("(refreshed 2d ago)")

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

  test "init scaffolds the repo-tier index and says to commit it" do
    Given "a project without a learnings index"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    accessor, _cache, project, = build_env(dir)
    out = StringIO.new

    When "running dev learnings init"
    accessor.run(["init"], out: out)

    Then "the canonical always-on index exists and the report points at committing it"
    index = Dev::Learnings::Layout.repo_index_file(project)
    index.file?
    index.read.include?("alwaysApply: true")
    out.string.include?("scaffolded #{index}")
    out.string.include?("commit")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "init --org scaffolds the knowledge-repo layout" do
    Given "a knowledge repo checkout without an index"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    accessor, _cache, project, = build_env(dir)
    out = StringIO.new

    When "running dev learnings init --org"
    accessor.run(["init", "--org"], out: out)

    Then "index.md carries the fixed section structure and skills/ exists beside it"
    index = Dev::Learnings::Layout.org_index_file(project)
    index.file?
    index.read.include?("## Invariants (always-on)")
    index.read.include?("## Knowledge (on-demand)")
    Dev::Learnings::Layout.org_skills_dir(project).directory?
    out.string.include?("scaffolded #{index}")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "init is idempotent — an existing index is reported and left untouched" do
    Given "a scaffolded project whose index has since been hand-edited"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    accessor, _cache, project, = build_env(dir)
    accessor.run(["init"], out: StringIO.new)
    index = Dev::Learnings::Layout.repo_index_file(project)
    index.write("# hand-curated entries\n")
    out = StringIO.new

    When "running dev learnings init again"
    accessor.run(["init"], out: out)

    Then "the run reports the write-once no-op and the index is untouched"
    out.string.include?("already exists")
    out.string.include?("write-once")
    index.read == "# hand-curated entries\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "init outside a project raises — there is nowhere to scaffold" do
    Given "a configured accessor with no enclosing project"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    accessor, = build_env(dir, project_root: nil)

    When "running dev learnings init"
    accessor.run(["init"], out: StringIO.new)

    Then
    raises Dev::Learnings::Accessor::NoEnclosingProjectError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "init with an unknown flag is rejected with usage" do
    Given "a configured accessor"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    accessor, = build_env(dir)

    When "running init with a flag that isn't --org"
    accessor.run(["init", "--bogus"], out: StringIO.new)

    Then
    raises Dev::Learnings::Accessor::UsageError

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
