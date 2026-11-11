# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/plan"
require "tmpdir"
require "fileutils"
require "json"
require "pathname"
require "stringio"
require "support/recording_ui"

# An in-memory stand-in for the GitHub Issues API, so accessor flows exercise
# the real workspace/merge/state machinery against real files while only the
# network boundary is faked. `edit_remotely` simulates a GH-side edit (web UI
# or another machine) that bumps updated_at.
class FakePlanIssues
  def initialize
    @issues = {}
    @files = {}
    @next_number = 1
    @clock = 0
  end

  def add_file(owner_repo, path, content)
    @files[[owner_repo, path]] = content
  end

  def repo_file(owner_repo, path)
    @files[[owner_repo, path]]
  end

  def create(owner_repo, title:, body:)
    number = @next_number
    @next_number += 1
    @issues[[owner_repo, number]] = Dev::Plan::GithubIssues::Issue.new(
      number: number, title: title, body: body, updated_at: tick,
      html_url: "https://github.com/#{owner_repo}/issues/#{number}",
    )
    get(owner_repo, number)
  end

  def get(owner_repo, number)
    @issues.fetch([owner_repo, number]).dup
  end

  def update(owner_repo, number, body:, title: nil)
    issue = @issues.fetch([owner_repo, number])
    issue.body = body
    issue.title = title if title
    issue.updated_at = tick
    issue.dup
  end

  def edit_remotely(owner_repo, number, body:)
    update(owner_repo, number, body: body)
  end

  private

  def tick
    @clock += 1
    format("2026-07-13T00:00:%02dZ", @clock)
  end
end unless defined?(FakePlanIssues)

# A settings stand-in with a fixed org plans repo (no config file needed).
class FakePlanSettings
  def plans_repo
    "d3mlabs/plans"
  end
end unless defined?(FakePlanSettings)

# A host service stand-in: plan flows are under test here, and the real
# service would read the machine's config and touch user-global dirs.
# A real HostService subclass so the accessor's typed seam accepts it; the
# hook-point verbs the plan command calls are no-ops (host hygiene is not
# under test here). No super in initialize: a noop needs no collaborators.
class NoopHostService < Dev::HostService
  def initialize; end
  def sync_skills(project_root: nil); end
  def sync_learnings(project_root: nil); end
end unless defined?(NoopHostService)

# A host service recording the hook-point calls, for the refresh test.
class RecordingHostService < NoopHostService
  attr_reader :calls

  def initialize
    super
    @calls = []
  end

  def sync_skills(project_root: nil)
    @calls << [:sync_skills, project_root]
  end

  def sync_learnings(project_root: nil)
    @calls << [:sync_learnings, project_root]
  end
end unless defined?(RecordingHostService)

transform!(RSpock::AST::Transformation)
class Dev::Plan::AccessorTest < Minitest::Test
  REPO = "d3mlabs/demo"

  # A real git repo (origin remote pointing at REPO), a fake issues API, and
  # state/skill dirs under the same tmpdir. The accessor speaks through the
  # given Ui — a fresh recording one when the test is not about what it
  # said. Returns [accessor, root, issues].
  def build_env(dir, ui: RecordingUi.new)
    project = File.join(dir, "repo")
    FileUtils.mkdir_p(project)
    system("git", "init", "-q", project, exception: true)
    system("git", "-C", project, "remote", "add", "origin", "git@github.com:#{REPO}.git", exception: true)
    root = Pathname.new(project)
    issues = FakePlanIssues.new
    accessor = Dev::Plan::Accessor.new(
      project_root: root,
      ui: ui,
      issues: issues,
      settings: FakePlanSettings.new,
      merge_base: Dev::Plan::MergeBase.new(state_dir: File.join(dir, "state")),
      host_service: NoopHostService.new,
    )
    [accessor, root, issues]
  end

  def read_plan(root, name)
    plan = Dev::Plan::Content.parse((root / ".cursor" / "plans" / name).read)
    [plan.header, plan.body, plan.frontmatter]
  end

  CURSOR_FRONTMATTER = <<~YAML
    ---
    name: Local picker label
    overview: Short overview
    todos:
      - id: step-one
        content: Do the thing
        status: pending
    isProject: false
    ---
  YAML

  test "new scaffolds the tech-design template by default (bundle fallback)" do
    Given "a workspace whose repo carries no plan template"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    ui = RecordingUi.new
    accessor, root, issues = build_env(dir, ui: ui)

    When "creating a plan"
    accessor.new_plan("Carve system", blank: false, org: false)

    Then "the issue body is the H1 plus dev's bundled template, the file is linked, and the verb is one frame: " \
         "the gh create as a spin, the result and the file as notes, no staleness warning"
    issues.get(REPO, 1).body.start_with?("# Carve system\n")
    issues.get(REPO, 1).body.include?("## Problem / Opportunity")
    issues.get(REPO, 1).body.include?("## Tech design")
    header, body = read_plan(root, "gh-1-carve-system.plan.md")
    header.issue_ref == "#{REPO}#1"
    header.synced_at == issues.get(REPO, 1).updated_at
    body == issues.get(REPO, 1).body
    ui.rows == [
      [:frame, "Creating \"Carve system\" at #{REPO}", 0],
      [:spin, "Creating the issue at #{REPO}", 1],
      [:note, "{{v}} created #{REPO}#1 (https://github.com/#{REPO}/issues/1)", 1],
      [:note, "plan file: #{root / ".cursor" / "plans" / "gh-1-carve-system.plan.md"}", 1],
    ]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "new --blank creates a bare plan (no template)" do
    Given "a workspace"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)

    When "creating a blank plan"
    accessor.new_plan("Carve system", blank: true, org: false)

    Then "the issue carries only the H1 and the file is linked to it"
    issues.get(REPO, 1).body == "# Carve system\n"
    header, body = read_plan(root, "gh-1-carve-system.plan.md")
    header.issue_ref == "#{REPO}#1"
    header.synced_at == issues.get(REPO, 1).updated_at
    body == "# Carve system\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "new uses a repo-owned plan template when present, silently" do
    Given "a repo-owned .github/ISSUE_TEMPLATE/plan.md (no dev marker)"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    ui = RecordingUi.new
    accessor, root, issues = build_env(dir, ui: ui)
    mirror = Dev::Plan::Templates.mirror_path(root)
    FileUtils.mkdir_p(mirror.dirname)
    mirror.write("---\nname: Custom plan\n---\n\n## Custom section\n\nRepo flavor.\n")

    When "creating a plan"
    accessor.new_plan("Carve system", blank: false, org: false)

    Then "the repo template body is scaffolded and no staleness warning fires"
    issues.get(REPO, 1).body == "# Carve system\n\n## Custom section\n\nRepo flavor.\n"
    !ui.out_text.include?("stale")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "new warns when the repo's mirror is stale vs dev's bundle, but still uses it" do
    Given "a marker-carrying mirror that drifted from the bundle"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    ui = RecordingUi.new
    accessor, root, issues = build_env(dir, ui: ui)
    mirror = Dev::Plan::Templates.mirror_path(root)
    FileUtils.mkdir_p(mirror.dirname)
    mirror.write("---\nname: Tech design\n---\n#{Dev::Plan::Templates::MARKER}\n\n## Old template section\n")

    When "creating a plan"
    accessor.new_plan("Carve system", blank: false, org: false)

    Then "the committed (stale) copy is authoritative and the warning, a {{x}} note inside the frame before the create, " \
         "points at dev plan init"
    issues.get(REPO, 1).body == "# Carve system\n\n## Old template section\n"
    ui.rows.take(2) == [
      [:frame, "Creating \"Carve system\" at #{REPO}", 0],
      [:note, "{{x}} #{REPO}'s plan template is stale vs dev's — run `dev plan init` in that repo, review with `git diff`, then commit.", 1],
    ]
    ui.rows[2] == [:spin, "Creating the issue at #{REPO}", 1]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "new --org fetches the plans repo template, falling back to the bundle" do
    Given "a plans repo carrying its own plan template"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    ui = RecordingUi.new
    accessor, _root, issues = build_env(dir, ui: ui)
    issues.add_file(
      "d3mlabs/plans", ".github/ISSUE_TEMPLATE/plan.md",
      "---\nname: Org plan\n---\n\n## Org section\n",
    )

    When "creating an org-wide plan"
    accessor.new_plan("Org roadmap", blank: false, org: true)

    Then "the fetched template body follows the Target repos scaffold; the fetch is a spin of its own, before the create"
    issues.get("d3mlabs/plans", 1).body.include?("Target repos:")
    issues.get("d3mlabs/plans", 1).body.include?("## Org section")
    ui.rows.select { |kind, _text, _depth| kind == :spin } == [
      [:spin, "Fetching d3mlabs/plans's plan template", 1],
      [:spin, "Creating the issue at d3mlabs/plans", 1],
    ]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "new --org targets the configured org plans repo" do
    Given "a workspace"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)

    When "creating an org-wide plan"
    accessor.new_plan("Org roadmap", blank: false, org: true)

    Then "the issue lands in the plans repo, scaffolded with a Target repos line, and the filename disambiguates"
    issues.get("d3mlabs/plans", 1).title == "Org roadmap"
    issues.get("d3mlabs/plans", 1).body.include?("Target repos:")
    header, body = read_plan(root, "gh-plans-1-org-roadmap.plan.md")
    header.owner_repo == "d3mlabs/plans"
    body.include?("Target repos:")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "push publishes local edits and records the new sync point" do
    Given "a linked plan with local edits"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    ui = RecordingUi.new
    accessor, root, issues = build_env(dir, ui: ui)
    accessor.new_plan("Carve system", blank: false, org: false)
    path = root / ".cursor" / "plans" / "gh-1-carve-system.plan.md"
    header, _body = Dev::Plan::Header.split(path.read)
    path.write(header.render + "# Carve system\n\nNew section.\n")
    ui.events.clear

    When "pushing"
    accessor.push(nil, org: false)

    Then "the issue body is updated and synced_at advances to the new updated_at; the verb frames the push, " \
         "spins the fetch and the update (both gh), and ends on the one-line result"
    issues.get(REPO, 1).body == "# Carve system\n\nNew section.\n"
    new_header, _new_body = Dev::Plan::Header.split(path.read)
    new_header.synced_at == issues.get(REPO, 1).updated_at
    ui.rows == [
      [:frame, "Pushing #{path} to #{REPO}#1", 0],
      [:spin, "Fetching #{REPO}#1", 1],
      [:spin, "Updating #{REPO}#1", 1],
      [:note, "{{v}} pushed #{path} to #{REPO}#1 (https://github.com/#{REPO}/issues/1)", 1],
    ]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "push with nothing to publish re-records the sync point and says the issue is in sync" do
    Given "a linked plan untouched since it was created"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    ui = RecordingUi.new
    accessor, _root, issues = build_env(dir, ui: ui)
    accessor.new_plan("Carve system", blank: true, org: false)
    ui.events.clear

    When "pushing"
    accessor.push(nil, org: false)

    Then "one fetch, no update, the in-sync line"
    issues.get(REPO, 1).body == "# Carve system\n"
    ui.rows.drop(1) == [
      [:spin, "Fetching #{REPO}#1", 1],
      [:note, "{{v}} #{REPO}#1 is already in sync.", 1],
    ]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "push renames the issue when the plan's H1 title changed" do
    Given "a linked plan whose H1 was edited"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    accessor.new_plan("Old title", blank: false, org: false)
    path = root / ".cursor" / "plans" / "gh-1-old-title.plan.md"
    header, _body = Dev::Plan::Header.split(path.read)
    path.write(header.render + "# New title\n")

    When "pushing"
    accessor.push(nil, org: false)

    Then
    issues.get(REPO, 1).title == "New title"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "push by issue number resolves the linked plan like pull does" do
    Given "two linked plans with local edits on the first"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    accessor.new_plan("Carve system", blank: true, org: false)
    accessor.new_plan("Second plan", blank: true, org: false)
    path = root / ".cursor" / "plans" / "gh-1-carve-system.plan.md"
    header, _body = Dev::Plan::Header.split(path.read)
    path.write(header.render + "# Carve system\n\nNew section.\n")

    When "pushing by number"
    accessor.push("1", org: false)

    Then "the right issue is updated even though the workspace holds several plans"
    issues.get(REPO, 1).body == "# Carve system\n\nNew section.\n"
    issues.get(REPO, 2).body == "# Second plan\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "push by number with --org resolves against the org plans repo" do
    Given "a linked org plan with local edits"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    accessor.new_plan("Org roadmap", blank: false, org: true)
    path = root / ".cursor" / "plans" / "gh-plans-1-org-roadmap.plan.md"
    header, _body = Dev::Plan::Header.split(path.read)
    path.write(header.render + "# Org roadmap\n\nScoped.\n")

    When "pushing by number with --org"
    accessor.push("1", org: true)

    Then
    issues.get("d3mlabs/plans", 1).body == "# Org roadmap\n\nScoped.\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "push by a number with no linked plan errors with pull-first guidance" do
    Given "a workspace with no linked plan for issue 7"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, _root, _issues = build_env(dir)

    When "pushing by that number"
    accessor.push("7", org: false)

    Then
    raises Dev::Plan::Accessor::UsageError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "push refuses when the remote body changed since the last sync" do
    Given "a linked plan whose issue was edited remotely"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    accessor.new_plan("Carve system", blank: false, org: false)
    issues.edit_remotely(REPO, 1, body: "# Carve system\n\nRemote addition.\n")
    path = root / ".cursor" / "plans" / "gh-1-carve-system.plan.md"
    header, _body = Dev::Plan::Header.split(path.read)
    path.write(header.render + "# Carve system\n\nLocal addition.\n")

    When "pushing"
    accessor.push(nil, org: false)

    Then "the guard rejects the clobber"
    raises RuntimeError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "pull overwrites a clean local copy with remote edits" do
    Given "a clean linked plan whose issue moved ahead"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    ui = RecordingUi.new
    accessor, root, issues = build_env(dir, ui: ui)
    accessor.new_plan("Carve system", blank: false, org: false)
    issues.edit_remotely(REPO, 1, body: "# Carve system\n\nRemote addition.\n")
    ui.events.clear

    When "pulling"
    accessor.pull(1, merge: false, org: false)

    Then "the local body matches the remote and synced_at advances; the frame holds the fetch and the result"
    header, body = read_plan(root, "gh-1-carve-system.plan.md")
    body == "# Carve system\n\nRemote addition.\n"
    header.synced_at == issues.get(REPO, 1).updated_at
    ui.rows == [
      [:frame, "Pulling #{REPO}#1", 0],
      [:spin, "Fetching #{REPO}#1", 1],
      [:note, "{{v}} pulled #{REPO}#1 into #{root / ".cursor" / "plans" / "gh-1-carve-system.plan.md"}", 1],
    ]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "pull of a clean copy whose issue did not move says it is up to date" do
    Given "a clean linked plan, remote untouched"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    ui = RecordingUi.new
    accessor, root, _issues = build_env(dir, ui: ui)
    accessor.new_plan("Carve system", blank: true, org: false)
    ui.events.clear

    When "pulling"
    accessor.pull(1, merge: false, org: false)

    Then
    ui.rows.last == [:note, "{{v}} #{root / ".cursor" / "plans" / "gh-1-carve-system.plan.md"} is already up to date.", 1]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "pull of a copy that is ahead leaves it and points at push" do
    Given "a linked plan with local edits, remote untouched"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    ui = RecordingUi.new
    accessor, root, _issues = build_env(dir, ui: ui)
    accessor.new_plan("Carve system", blank: true, org: false)
    path = root / ".cursor" / "plans" / "gh-1-carve-system.plan.md"
    header, _body = Dev::Plan::Header.split(path.read)
    path.write(header.render + "# Carve system\n\nLocal addition.\n")
    ui.events.clear

    When "pulling"
    accessor.pull(1, merge: false, org: false)

    Then "the local edits stand and the note says why nothing was pulled"
    Dev::Plan::Content.parse(path.read).body == "# Carve system\n\nLocal addition.\n"
    ui.rows.last == [:note, "local plan is ahead of #{REPO}#1 — nothing to pull. Run `dev plan push`.", 1]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "pull creates the local plan when none exists (load issue as plan)" do
    Given "an issue with no local copy"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    ui = RecordingUi.new
    accessor, root, issues = build_env(dir, ui: ui)
    issues.create(REPO, title: "Remote-born plan", body: "# Remote-born plan\n")

    When "pulling it"
    accessor.pull(1, merge: false, org: false)

    Then "a linked plan file materializes, and the result names it — the line an agent opens"
    header, body = read_plan(root, "gh-1-remote-born-plan.plan.md")
    header.issue_ref == "#{REPO}#1"
    body == "# Remote-born plan\n"
    ui.rows.last == [:note, "{{v}} pulled #{REPO}#1 into #{root / ".cursor" / "plans" / "gh-1-remote-born-plan.plan.md"}", 1]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "pull without --merge refuses when both sides changed" do
    Given "a diverged plan"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    accessor.new_plan("Carve system", blank: false, org: false)
    issues.edit_remotely(REPO, 1, body: "# Carve system\n\nRemote addition.\n")
    path = root / ".cursor" / "plans" / "gh-1-carve-system.plan.md"
    header, _body = Dev::Plan::Header.split(path.read)
    path.write(header.render + "# Carve system\n\nLocal addition.\n")

    When "pulling without --merge"
    accessor.pull(1, merge: false, org: false)

    Then
    raises RuntimeError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "pull --merge integrates non-overlapping edits from both sides" do
    Given "a diverged plan with non-overlapping edits"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    ui = RecordingUi.new
    accessor, root, issues = build_env(dir, ui: ui)
    base = "# Plan\n\nalpha\n\none\ntwo\nthree\nfour\n\nomega\n"
    issues.create(REPO, title: "Plan", body: "#{base}\n")
    accessor.pull(1, merge: false, org: false)
    issues.edit_remotely(REPO, 1, body: "#{base.sub("omega", "omega REMOTE")}\n")
    path = root / ".cursor" / "plans" / "gh-1-plan.plan.md"
    header, _body = Dev::Plan::Header.split(path.read)
    path.write(header.render + base.sub("alpha", "alpha LOCAL"))
    ui.events.clear

    When "pulling with --merge, then pushing the merged result"
    accessor.pull(1, merge: true, org: false)
    accessor.push(nil, org: false)

    Then "both edits are in the issue; the merge (git, captured) spun inside the pull's frame and its result points at push"
    issues.get(REPO, 1).body == base.sub("alpha", "alpha LOCAL").sub("omega", "omega REMOTE")
    ui.rows.take(4) == [
      [:frame, "Pulling #{REPO}#1", 0],
      [:spin, "Fetching #{REPO}#1", 1],
      [:spin, "Merging #{REPO}#1 into #{path}", 1],
      [:note, "{{v}} merged #{REPO}#1 into #{path} — run `dev plan push` to publish.", 1],
    ]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "push refuses while the file holds unresolved conflict markers" do
    Given "a merge that conflicted"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    ui = RecordingUi.new
    accessor, root, issues = build_env(dir, ui: ui)
    accessor.new_plan("Plan", blank: false, org: false)
    issues.edit_remotely(REPO, 1, body: "# Plan remote\n")
    path = root / ".cursor" / "plans" / "gh-1-plan.plan.md"
    header, _body = Dev::Plan::Header.split(path.read)
    path.write(header.render + "# Plan local\n")
    accessor.pull(1, merge: true, org: false)

    When "pushing without resolving the markers"
    accessor.push(nil, org: false)

    Then "the refusal, after the merge's own result had flagged the conflicts"
    raises RuntimeError
    ui.rows.last == [:note, "{{x}} merged with conflicts — resolve the markers in #{path}, then run `dev plan push`.", 1]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "link <n> attaches an existing draft to an issue, keeping local content" do
    Given "an unlinked draft and an existing issue"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    ui = RecordingUi.new
    accessor, root, issues = build_env(dir, ui: ui)
    issues.create(REPO, title: "Existing issue", body: "# Existing issue\n")
    draft = root / ".cursor" / "plans" / "draft.plan.md"
    FileUtils.mkdir_p(draft.dirname)
    draft.write("# My draft\n\nLocal thinking.\n")

    When "linking the draft to issue 1 and pushing"
    accessor.link("1", file: draft.to_s, org: false)
    accessor.push(nil, org: false)

    Then "the draft moved to the conventional name and its content is published; the link's frame fetched the issue " \
         "and said what it kept"
    !draft.exist?
    header, _body = read_plan(root, "gh-1-existing-issue.plan.md")
    header.issue_ref == "#{REPO}#1"
    issues.get(REPO, 1).body == "# My draft\n\nLocal thinking.\n"
    linked = root / ".cursor" / "plans" / "gh-1-existing-issue.plan.md"
    ui.rows.take(4) == [
      [:frame, "Linking #{draft} to #{REPO}#1", 0],
      [:spin, "Fetching #{REPO}#1", 1],
      [:note, "{{v}} linked #{linked} to #{REPO}#1 (https://github.com/#{REPO}/issues/1)", 1],
      [:note, "local content kept — run `dev plan push` to publish it.", 1],
    ]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "link <file> creates a new issue from the draft (canonize)" do
    Given "an unlinked draft"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    ui = RecordingUi.new
    accessor, root, issues = build_env(dir, ui: ui)
    draft = root / ".cursor" / "plans" / "draft.plan.md"
    FileUtils.mkdir_p(draft.dirname)
    draft.write("# Fresh plan\n\nContent.\n")

    When "canonizing it"
    accessor.link(draft.to_s, file: nil, org: false)

    Then "the issue is created from the H1 title with the draft's body; one frame, the create spun, the result and the file noted"
    issues.get(REPO, 1).title == "Fresh plan"
    issues.get(REPO, 1).body == "# Fresh plan\n\nContent.\n"
    header, _body = read_plan(root, "gh-1-fresh-plan.plan.md")
    header.issue_ref == "#{REPO}#1"
    ui.rows == [
      [:frame, "Creating an issue from #{draft} at #{REPO}", 0],
      [:spin, "Creating the issue at #{REPO}", 1],
      [:note, "{{v}} created #{REPO}#1 from #{draft} (https://github.com/#{REPO}/issues/1)", 1],
      [:note, "plan file: #{root / ".cursor" / "plans" / "gh-1-fresh-plan.plan.md"}", 1],
    ]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "link <file> ships only the markdown body when Cursor put a session comment above the frontmatter (dev#198)" do
    Given "an unlinked draft in the layout Cursor's plan tool writes: session comment, frontmatter, markdown"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    draft = root / ".cursor" / "plans" / "draft.plan.md"
    FileUtils.mkdir_p(draft.dirname)
    session_comment = "<!-- 0396ea46-2344-40be-8e3b-e14cb3d4ffa5 -->\n"
    frontmatter = "---\ntodos:\n  - id: \"a\"\n    content: \"do it\"\n    status: pending\nisProject: false\n---\n"
    draft.write("#{session_comment}#{frontmatter}# Fresh plan\n\nContent.\n")

    When "canonizing it"
    accessor.link(draft.to_s, file: nil, org: false)

    Then "the issue body is the markdown alone, and the local file keeps the comment and frontmatter under the header"
    issues.get(REPO, 1).body == "# Fresh plan\n\nContent.\n"
    linked = Dev::Plan::Content.parse((root / ".cursor" / "plans" / "gh-1-fresh-plan.plan.md").read)
    linked.header.issue_ref == "#{REPO}#1"
    linked.session_comment == session_comment
    linked.frontmatter == frontmatter
    linked.body == "# Fresh plan\n\nContent.\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status reports clean, ahead, behind, and diverged plans" do
    Given "four linked plans in each sync state"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    ui = RecordingUi.new
    accessor, root, issues = build_env(dir, ui: ui)
    accessor.new_plan("Clean plan", blank: false, org: false)
    accessor.new_plan("Ahead plan", blank: false, org: false)
    accessor.new_plan("Behind plan", blank: false, org: false)
    accessor.new_plan("Diverged plan", blank: false, org: false)
    plans = root / ".cursor" / "plans"
    [["gh-2-ahead-plan.plan.md", 2], ["gh-4-diverged-plan.plan.md", 4]].each do |name, _n|
      path = plans / name
      header, body = Dev::Plan::Header.split(path.read)
      path.write(header.render + body + "\nlocal edit\n")
    end
    issues.edit_remotely(REPO, 3, body: "# Behind plan\n\nremote edit\n")
    issues.edit_remotely(REPO, 4, body: "# Diverged plan\n\nremote edit\n")
    ui.events.clear

    When "listing status"
    accessor.status

    Then "one frame for the plans dir: the footprint fact first, a fetch spun per issue, then one aligned line per plan"
    ui.rows.take(6) == [
      [:frame, "Linked plans (#{plans})", 0],
      [:note, "{{x}} .cursor/plans/ is not gitignored — run `dev learnings init --gitignore`.", 1],
      [:spin, "Fetching #{REPO}#1", 1],
      [:spin, "Fetching #{REPO}#2", 1],
      [:spin, "Fetching #{REPO}#3", 1],
      [:spin, "Fetching #{REPO}#4", 1],
    ]
    ui.rows.drop(6) == [
      [:note, "#{"clean".ljust(10)} #{"#{REPO}#1".ljust(30)} #{plans / "gh-1-clean-plan.plan.md"}", 1],
      [:note, "#{"ahead".ljust(10)} #{"#{REPO}#2".ljust(30)} #{plans / "gh-2-ahead-plan.plan.md"}", 1],
      [:note, "#{"behind".ljust(10)} #{"#{REPO}#3".ljust(30)} #{plans / "gh-3-behind-plan.plan.md"}", 1],
      [:note, "#{"diverged".ljust(10)} #{"#{REPO}#4".ljust(30)} #{plans / "gh-4-diverged-plan.plan.md"}", 1],
    ]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status is silent about the footprint when the plans dir is gitignored" do
    Given "a repo ignoring .cursor/plans/ and no linked plans"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    ui = RecordingUi.new
    accessor, root, = build_env(dir, ui: ui)
    (root / ".gitignore").write(".cursor/plans/\n")

    When "listing status"
    accessor.status

    Then "the frame holds only the no-plans line"
    ui.rows == [
      [:frame, "Linked plans (#{root / ".cursor" / "plans"})", 0],
      [:note, "no linked plans in #{root / ".cursor" / "plans"}.", 1],
    ]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "hook-after-edit auto-pushes an edited linked plan" do
    Given "a linked plan with fresh local edits, as the afterFileEdit hook sees it"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    accessor.new_plan("Carve system", blank: false, org: false)
    path = root / ".cursor" / "plans" / "gh-1-carve-system.plan.md"
    header, _body = Dev::Plan::Header.split(path.read)
    path.write(header.render + "# Carve system\n\nAgent edit.\n")
    payload = StringIO.new(JSON.generate(file_path: path.to_s))

    When "the hook fires"
    accessor.hook_after_edit(payload)

    Then "the edit is on the issue"
    issues.get(REPO, 1).body == "# Carve system\n\nAgent edit.\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "hook-after-edit no-ops for unlinked plans and non-plan files" do
    Given "an unlinked draft and a source file"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, _issues = build_env(dir)
    draft = root / ".cursor" / "plans" / "draft.plan.md"
    FileUtils.mkdir_p(draft.dirname)
    draft.write("# Draft\n")
    source = root / "main.rb"
    source.write("puts 1\n")

    When "the hook fires for each"
    accessor.hook_after_edit(StringIO.new(JSON.generate(file_path: draft.to_s)))
    accessor.hook_after_edit(StringIO.new(JSON.generate(file_path: source.to_s)))

    Then "nothing raises and nothing syncs (no issues exist to sync to)"
    draft.read == "# Draft\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "push on an unlinked file raises UsageError" do
    Given "an unlinked draft"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, _issues = build_env(dir)
    draft = root / ".cursor" / "plans" / "draft.plan.md"
    FileUtils.mkdir_p(draft.dirname)
    draft.write("# Draft\n")

    When "pushing it explicitly"
    accessor.push(draft.to_s, org: false)

    Then
    raises Dev::Plan::Accessor::UsageError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "link and push ship markdown only — Cursor frontmatter stays local" do
    Given "a Cursor draft with YAML frontmatter"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    draft = root / ".cursor" / "plans" / "draft.plan.md"
    FileUtils.mkdir_p(draft.dirname)
    draft.write("#{CURSOR_FRONTMATTER}# Squeeze visual\n\nImprove the membrane.\n")

    When "canonizing and pushing"
    accessor.link(draft.to_s, file: nil, org: false)

    Then "the issue body is markdown-only and the local file keeps frontmatter"
    issues.get(REPO, 1).title == "Squeeze visual"
    issues.get(REPO, 1).body == "# Squeeze visual\n\nImprove the membrane.\n"
    !issues.get(REPO, 1).body.include?("isProject:")
    header, body, frontmatter = read_plan(root, "gh-1-squeeze-visual.plan.md")
    header.issue_ref == "#{REPO}#1"
    body == "# Squeeze visual\n\nImprove the membrane.\n"
    frontmatter == CURSOR_FRONTMATTER

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "pull preserves local Cursor frontmatter while replacing the markdown body" do
    Given "a linked plan with local frontmatter whose issue moved ahead"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    accessor.new_plan("Carve system", blank: false, org: false)
    path = root / ".cursor" / "plans" / "gh-1-carve-system.plan.md"
    plan = Dev::Plan::Content.parse(path.read)
    path.write(Dev::Plan::Content.new(
      header: plan.header, frontmatter: CURSOR_FRONTMATTER, body: plan.body,
    ).render)
    issues.edit_remotely(REPO, 1, body: "# Carve system\n\nRemote addition.\n")

    When "pulling"
    accessor.pull(1, merge: false, org: false)

    Then "the markdown matches the remote and frontmatter is untouched"
    _header, body, frontmatter = read_plan(root, "gh-1-carve-system.plan.md")
    body == "# Carve system\n\nRemote addition.\n"
    frontmatter == CURSOR_FRONTMATTER

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "frontmatter-only edits leave the plan clean and push is a no-op" do
    Given "a linked plan whose only local change is Cursor todos"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    ui = RecordingUi.new
    accessor, root, issues = build_env(dir, ui: ui)
    accessor.new_plan("Carve system", blank: true, org: false)
    path = root / ".cursor" / "plans" / "gh-1-carve-system.plan.md"
    plan = Dev::Plan::Content.parse(path.read)
    path.write(Dev::Plan::Content.new(
      header: plan.header, frontmatter: CURSOR_FRONTMATTER, body: plan.body,
    ).render)

    When "checking status and pushing"
    accessor.status
    accessor.push(nil, org: false)

    Then "status is clean, the issue is unchanged, and frontmatter remains local"
    ui.out_text.match?(/^clean\s+#{REPO}#1/)
    issues.get(REPO, 1).body == "# Carve system\n"
    _header, body, frontmatter = read_plan(root, "gh-1-carve-system.plan.md")
    body == "# Carve system\n"
    frontmatter == CURSOR_FRONTMATTER

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "pull --merge merges markdown only and keeps local frontmatter" do
    Given "a diverged plan with local Cursor frontmatter"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    base = "# Plan\n\nalpha\n\none\ntwo\nthree\nfour\n\nomega\n"
    issues.create(REPO, title: "Plan", body: "#{base}\n")
    accessor.pull(1, merge: false, org: false)
    path = root / ".cursor" / "plans" / "gh-1-plan.plan.md"
    plan = Dev::Plan::Content.parse(path.read)
    path.write(Dev::Plan::Content.new(
      header: plan.header,
      frontmatter: CURSOR_FRONTMATTER,
      body: base.sub("alpha", "alpha LOCAL"),
    ).render)
    issues.edit_remotely(REPO, 1, body: "#{base.sub("omega", "omega REMOTE")}\n")

    When "pulling with --merge"
    accessor.pull(1, merge: true, org: false)

    Then "both markdown edits land and frontmatter is preserved"
    _header, body, frontmatter = read_plan(root, "gh-1-plan.plan.md")
    body == base.sub("alpha", "alpha LOCAL").sub("omega", "omega REMOTE")
    frontmatter == CURSOR_FRONTMATTER

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "init scaffolds the plan template mirror into the repo" do
    Given "a repo without a plan template"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    ui = RecordingUi.new
    accessor, root, _issues = build_env(dir, ui: ui)

    When "running init"
    accessor.init

    Then "the mirror is written verbatim from the bundle render; the frame names the mirror, the result says commit"
    mirror = Dev::Plan::Templates.mirror_path(root)
    mirror.read == Dev::Plan::Templates.render_mirror
    ui.rows == [
      [:frame, "Plan template mirror (#{mirror})", 0],
      [:note, "{{v}} created #{mirror} — commit it to serve the plan template from GitHub too.", 1],
    ]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "init is a no-op when the mirror is already up to date" do
    Given "a freshly scaffolded mirror"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    ui = RecordingUi.new
    accessor, root, _issues = build_env(dir, ui: ui)
    accessor.init
    ui.events.clear

    When "running init again"
    accessor.init

    Then
    Dev::Plan::Templates.mirror_path(root).read == Dev::Plan::Templates.render_mirror
    ui.rows.last == [:note, "{{v}} #{Dev::Plan::Templates.mirror_path(root)} is up to date.", 1]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "init updates a stale marker-carrying mirror" do
    Given "a mirror that drifted from the bundle"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    ui = RecordingUi.new
    accessor, root, _issues = build_env(dir, ui: ui)
    mirror = Dev::Plan::Templates.mirror_path(root)
    FileUtils.mkdir_p(mirror.dirname)
    mirror.write("---\nname: Tech design\n---\n#{Dev::Plan::Templates::MARKER}\n\n## Old template section\n")

    When "running init"
    accessor.init

    Then "the mirror is overwritten and the result points at git diff for review"
    mirror.read == Dev::Plan::Templates.render_mirror
    ui.rows.last == [:note, "{{v}} updated #{mirror} — review with `git diff`, then commit.", 1]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "init leaves a repo-owned template (no marker) untouched" do
    Given "a repo that owns its plan template"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    ui = RecordingUi.new
    accessor, root, _issues = build_env(dir, ui: ui)
    mirror = Dev::Plan::Templates.mirror_path(root)
    FileUtils.mkdir_p(mirror.dirname)
    owned = "---\nname: Custom plan\n---\n\n## Custom section\n"
    mirror.write(owned)

    When "running init"
    accessor.init

    Then "the file is untouched and reported as repo-owned — a fact, not a failure, so no glyph"
    mirror.read == owned
    ui.rows.last == [:note, "#{mirror} is repo-owned (no dev marker) — left untouched.", 1]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "push strips previously published frontmatter from the issue body" do
    Given "an issue that still carries Cursor frontmatter from the old sync bug"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    polluted = "#{CURSOR_FRONTMATTER}# Carve system\n"
    issue = issues.create(REPO, title: "Carve system", body: polluted)
    path = root / ".cursor" / "plans" / "gh-1-carve-system.plan.md"
    FileUtils.mkdir_p(path.dirname)
    header = Dev::Plan::Header.new(owner_repo: REPO, number: 1, synced_at: issue.updated_at)
    path.write(Dev::Plan::Content.new(
      header: header, frontmatter: CURSOR_FRONTMATTER, body: "# Carve system\n",
    ).render)
    merge_base = Dev::Plan::MergeBase.new(state_dir: File.join(dir, "state"))
    merge_base.write(REPO, 1, polluted)

    When "pushing the linked plan"
    accessor.push(path.to_s, org: false)

    Then "the issue is cleaned to markdown-only"
    issues.get(REPO, 1).body == "# Carve system\n"
    !issues.get(REPO, 1).body.include?("---\n")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "refresh_host converges the shipped skills and the org learnings for the workspace" do
    Given "an accessor over a recording host service"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    host = RecordingHostService.new
    root = Pathname.new(dir)
    ui = RecordingUi.new
    accessor = Dev::Plan::Accessor.new(project_root: root, ui: ui, issues: FakePlanIssues.new,
      settings: FakePlanSettings.new, host_service: host)

    When "refreshing"
    accessor.refresh_host

    Then "skills first, then learnings scoped to the workspace root — silently: hygiene riding a verb says nothing"
    host.calls == [[:sync_skills, root], [:sync_learnings, root]]
    ui.rows == []

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
