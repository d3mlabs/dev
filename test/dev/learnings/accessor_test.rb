# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/learnings"
require "dev/settings"
require "dev/skills"
require "pathname"
require "tmpdir"
require "fileutils"
require "stringio"
require "support/recording_ui"

transform!(RSpock::AST::Transformation)
class Dev::Learnings::AccessorTest < Minitest::Test
  # A real git source repo plus a fully tmpdir-scoped accessor (nothing
  # touches the real user config, cache, or skills). Returns the accessor and
  # the pieces we assert on.
  def build_env(dir, project_root: :default, ui: RecordingUi.new)
    source = build_source_repo(dir)
    config = File.join(dir, "config.yml")
    File.write(config, "knowledge_repo: #{source}\n")
    settings = hermetic_settings(dir)
    cache = Dev::Learnings::Cache.new(repo: source, dir: File.join(dir, "cache"))
    # The fixture cache lives under the real temp dir; the tmpdir override
    # keeps the installer's ephemeral-source guard out of these tests' way.
    materializer = Dev::Skills::Materializer.new(
      installer_factory: ->(root) { Dev::Skills::Installer.new(skills_dir: root, tmpdir: File.join(dir, "tmp")) },
    )
    synchronizer = Dev::Learnings::Synchronizer.new(
      settings: settings, cache: cache, materializer: materializer, skills_root: File.join(dir, "user-skills"),
    )
    project = project_root == :default ? Pathname(dir) / "repo" : project_root
    if project
      # A real git repo, so the footprint check (`git check-ignore`) has
      # something to answer against.
      FileUtils.mkdir_p(project)
      system("git", "-C", project.to_s, "init", "-q", exception: true)
    end
    accessor = Dev::Learnings::Accessor.new(
      project_root: project, ui: ui, settings: settings, cache: cache, synchronizer: synchronizer,
    )
    [accessor, cache, project, synchronizer]
  end

  # Settings with both file layers pinned inside the temp dir — the
  # machine's real system config (installed by a deployment formula) must
  # never leak a knowledge_repo into these tests.
  def hermetic_settings(dir)
    Dev::Settings.new(
      config_path: File.join(dir, "config.yml"),
      system_config_path: File.join(dir, "system-config.yml"),
    )
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

  test "learnings sync refreshes the org tier and reports" do
    Given "a configured accessor with no cache yet"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    ui = RecordingUi.new
    accessor, cache, project, synchronizer = build_env(dir, ui: ui)

    When "running dev learnings sync"
    accessor.sync

    Then "cache cloned, org skill linked, invariants rendered + linked; one frame, the pull spun (git, captured), " \
         "a fact per artifact, the one-line result last"
    cache.present?
    File.symlink?(File.join(dir, "user-skills", "srp"))
    synchronizer.rendered_invariants_file.file?
    (project / ".cursor" / "rules" / "org-invariants.mdc").symlink?
    repo = File.join(dir, "knowledge")
    ui.rows == [
      [:frame, "Syncing the org learnings from #{repo}", 0],
      [:spin, "Pulling #{repo} into #{cache.dir} and distributing it", 1],
      [:note, "{{v}} invariants rendered at #{synchronizer.rendered_invariants_file}", 1],
      [:note, "{{v}} invariants linked at #{project / ".cursor" / "rules" / "org-invariants.mdc"}", 1],
      [:note, "{{v}} learnings synced from #{repo} (#{cache.dir}).", 1],
    ]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "learnings sync outside a project does the machine-global parts and says what it skipped" do
    Given "a configured accessor with no enclosing project"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    ui = RecordingUi.new
    accessor, cache, _project, synchronizer, = build_env(dir, project_root: nil, ui: ui)

    When "running dev learnings sync"
    accessor.sync

    Then "cache and machine-side render exist; the project-scoped parts were skipped, and the frame says so"
    cache.present?
    synchronizer.rendered_invariants_file.file?
    ui.rows.include?([:note, "no enclosing project — skipped the invariants link.", 1])

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "learnings sync with no knowledge repo configured raises the null synchronizer's refusal before any frame" do
    Given "an accessor over empty settings"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    saved_env = ENV.delete("DEV_KNOWLEDGE_REPO")
    ui = RecordingUi.new
    accessor = Dev::Learnings::Accessor.new(project_root: dir, ui: ui, settings: hermetic_settings(dir))

    When "running dev learnings sync"
    accessor.sync

    Then
    raises Dev::Learnings::Synchronizer::KnowledgeRepoNotConfiguredError
    ui.rows == []

    Cleanup
    ENV["DEV_KNOWLEDGE_REPO"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "status reports a missing configuration with instructions" do
    Given "an accessor over empty settings"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    saved_env = ENV.delete("DEV_KNOWLEDGE_REPO")
    ui = RecordingUi.new
    accessor = Dev::Learnings::Accessor.new(project_root: dir, ui: ui, settings: hermetic_settings(dir))

    When "running dev learnings status"
    accessor.status

    Then "one bare note names the setting and the ENV override — unconfigured is a supported state, not a drift"
    ui.rows.size == 1
    ui.rows.first == [
      :note,
      "no knowledge repo configured — add `knowledge_repo: <owner>/<repo>` to #{File.join(dir, "config.yml")} " \
        "(or set DEV_KNOWLEDGE_REPO).",
      0,
    ]

    Cleanup
    ENV["DEV_KNOWLEDGE_REPO"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "status before the first clone points at dev learnings sync" do
    Given "a configured accessor with no cache yet"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    ui = RecordingUi.new
    accessor, cache, = build_env(dir, ui: ui)

    When "running dev learnings status"
    accessor.status

    Then "the org frame holds one {{x}} fact with the remedy; no project frame before the cache exists"
    ui.rows == [
      [:frame, "Org learnings (#{File.join(dir, "knowledge")})", 0],
      [:note, "{{x}} cache: #{cache.dir} (not cloned yet — run `dev learnings sync`).", 1],
    ]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status after a sync reports each tier's rendered/linked artifacts" do
    Given "a fully synced read path"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    ui = RecordingUi.new
    accessor, cache, project, synchronizer = build_env(dir, ui: ui)
    accessor.sync
    ui.events.clear

    When "running dev learnings status"
    accessor.status

    Then "a frame per tier: cache age and the machine-side render under the org, the link and its footprint " \
         "under the project — the footprint a {{x}} for the unscaffolded repo"
    ui.rows.size == 6
    ui.rows[0] == [:frame, "Org learnings (#{File.join(dir, "knowledge")})", 0]
    ui.rows[1][1].match?(/\A\{\{v\}\} cache: #{Regexp.escape(cache.dir.to_s)} \(refreshed \d+s ago\)\.\z/)
    ui.rows[2] == [:note, "{{v}} invariants: rendered at #{synchronizer.rendered_invariants_file}.", 1]
    ui.rows[3] == [:frame, "Project (#{project})", 0]
    ui.rows[4] == [:note, "{{v}} invariants link: #{project / ".cursor" / "rules" / "org-invariants.mdc"} (linked).", 1]
    ui.rows[5] == [:note, "{{x}} .cursor/rules/org-invariants.mdc is not gitignored — run `dev learnings init --gitignore`.", 1]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status with a cloned but never-synced cache points both tiers at dev learnings sync" do
    Given "a cloned cache that has never been distributed"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    ui = RecordingUi.new
    accessor, cache, project, = build_env(dir, ui: ui)
    cache.refresh

    When "running dev learnings status"
    accessor.status

    Then "the org render and the project link are both {{x}} facts with the remedy"
    ui.rows.include?([:note, "{{x}} invariants: not rendered (no invariants section in the index, or never synced).", 1])
    ui.rows.include?([
      :note,
      "{{x}} invariants link: #{project / ".cursor" / "rules" / "org-invariants.mdc"} (missing — run `dev learnings sync`).",
      1,
    ])

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status flags an invariants rules file that is not dev's link" do
    Given "a synced project whose rules file was replaced by a plain file"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    ui = RecordingUi.new
    accessor, _cache, project, synchronizer, = build_env(dir, ui: ui)
    accessor.sync
    rules_file = synchronizer.project_rules_file(project)
    rules_file.delete
    rules_file.write("# hand-rolled, not dev's symlink\n")

    When "running dev learnings status"
    accessor.status

    Then
    ui.rows.include?([:note, "{{x}} invariants link: #{rules_file} (present but not dev's link — run `dev learnings sync`).", 1])

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status formats the cache age in minutes, hours, and days" do
    Given "a synced accessor"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    ui = RecordingUi.new
    accessor, cache, = build_env(dir, ui: ui)
    accessor.sync

    When "running status with the cache's sync marker backdated to each granularity"
    [5 * 60, 3 * 3600, 2 * 86_400].each do |age_seconds|
      backdate_cache(cache, age_seconds)
      accessor.status
    end

    Then "each report carries the compact age"
    ui.out_text.include?("(refreshed 5m ago)")
    ui.out_text.include?("(refreshed 3h ago)")
    ui.out_text.include?("(refreshed 2d ago)")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status without a project reports the machine tiers and says the project is absent" do
    Given "a synced accessor with no enclosing project"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    ui = RecordingUi.new
    accessor, = build_env(dir, project_root: nil, ui: ui)
    accessor.sync
    ui.events.clear

    When "running dev learnings status"
    accessor.status

    Then "the org frame, then a bare pointer in place of the project frame"
    ui.rows[2][1].start_with?("{{v}} invariants: rendered at")
    ui.rows.last == [:note, "project: none — run inside a repo to see its invariants link.", 0]

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
    accessor.invariants(out: out)

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
    accessor = Dev::Learnings::Accessor.new(project_root: dir, ui: RecordingUi.new, settings: hermetic_settings(dir))

    When "running dev learnings invariants"
    accessor.invariants(out: StringIO.new)

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
    accessor.invariants(out: StringIO.new)

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
    accessor.invariants(out: StringIO.new)

    Then
    raises Dev::Learnings::Accessor::InvariantsUnavailableError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "init scaffolds the repo-tier index and says to commit it" do
    Given "a project without a learnings index"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    ui = RecordingUi.new
    accessor, _cache, project, = build_env(dir, ui: ui)

    When "running dev learnings init"
    accessor.init

    Then "the canonical always-on index exists, the .gitignore carries dev's footprint, and the frame reports both"
    index = Dev::Learnings::Layout.repo_index_file(project)
    index.file?
    index.read.include?("alwaysApply: true")
    (project / ".gitignore").read.include?(Dev::Footprint::HEADER)
    Dev::Footprint::MANAGED_PATHS.all? { |path| (project / ".gitignore").read.include?("#{path}\n") }
    ui.rows == [
      [:frame, "Learnings scaffold (#{project})", 0],
      [:note, "{{v}} scaffolded #{index} (this repo's empty always-on learnings index) — commit it.", 1],
      [:note, "{{v}} added .cursor/rules/org-invariants.mdc, .agents/skills/dev/, .cursor/plans/ to .gitignore " \
        "(dev's managed footprint) — commit it.", 1],
    ]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "init --gitignore only ensures the footprint, leaving an absent index absent" do
    Given "a project without a learnings index"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    ui = RecordingUi.new
    accessor, _cache, project, = build_env(dir, ui: ui)

    When "running dev learnings init --gitignore"
    accessor.init(gitignore_only: true)

    Then "the .gitignore is written, no index is scaffolded"
    (project / ".gitignore").read.include?(Dev::Footprint::HEADER)
    !Dev::Learnings::Layout.repo_index_file(project).exist?
    !ui.out_text.include?("scaffolded")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "init --org scaffolds the knowledge-repo layout" do
    Given "a knowledge repo checkout without an index"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    ui = RecordingUi.new
    accessor, _cache, project, = build_env(dir, ui: ui)

    When "running dev learnings init --org"
    accessor.init(org: true)

    Then "index.md carries the fixed section structure and skills/ exists beside it"
    index = Dev::Learnings::Layout.org_index_file(project)
    index.file?
    index.read.include?("## Invariants (always-on)")
    index.read.include?("## Knowledge (on-demand)")
    Dev::Learnings::Layout.org_skills_dir(project).directory?
    ui.rows == [
      [:frame, "Org knowledge-repo scaffold (#{project})", 0],
      [:note, "{{v}} scaffolded #{index} and #{Dev::Learnings::Layout.org_skills_dir(project)}/ " \
        "(the org knowledge-repo layout) — commit them.", 1],
    ]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "init is idempotent — an existing index is reported and left untouched" do
    Given "a scaffolded project whose index has since been hand-edited"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    ui = RecordingUi.new
    accessor, _cache, project, = build_env(dir, ui: ui)
    accessor.init
    index = Dev::Learnings::Layout.repo_index_file(project)
    index.write("# hand-curated entries\n")
    ui.events.clear

    When "running dev learnings init again"
    accessor.init

    Then "the run reports the write-once no-op (a fact, no glyph) and the index is untouched; " \
         "the .gitignore step reports it is covered"
    ui.rows.size == 3
    ui.rows[1][0] == :note
    ui.rows[1][1].include?("already exists")
    ui.rows[1][1].include?("write-once")
    !ui.rows[1][1].start_with?("{{")
    index.read == "# hand-curated entries\n"
    ui.rows[2] == [:note, "{{v}} .gitignore already covers dev's managed footprint.", 1]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "init outside a project raises — there is nowhere to scaffold" do
    Given "a configured accessor with no enclosing project"
    dir = Dir.mktmpdir("dev-learnings-acc-test-")
    accessor, = build_env(dir, project_root: nil)

    When "running dev learnings init"
    accessor.init

    Then
    raises Dev::Learnings::Accessor::NoEnclosingProjectError

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
