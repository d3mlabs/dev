# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/plan"
require "tmpdir"
require "fileutils"
require "json"
require "pathname"
require "stringio"

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
  def plans_repo = "d3mlabs/plans"
end unless defined?(FakePlanSettings)

# A host service stand-in: plan flows are under test here, and the real
# service would read the machine's config and touch user-global dirs.
class NoopHostService
  def install_skills; end
  def sync_learnings(project_root: nil); end
end unless defined?(NoopHostService)

transform!(RSpock::AST::Transformation)
class Dev::Plan::AccessorTest < Minitest::Test
  REPO = "d3mlabs/demo"

  # A real git repo (origin remote pointing at REPO), a fake issues API, and
  # state/skill dirs under the same tmpdir. Returns [accessor, root, issues].
  def build_env(dir)
    project = File.join(dir, "repo")
    FileUtils.mkdir_p(project)
    system("git", "init", "-q", project, exception: true)
    system("git", "-C", project, "remote", "add", "origin", "git@github.com:#{REPO}.git", exception: true)
    root = Pathname.new(project)
    issues = FakePlanIssues.new
    accessor = Dev::Plan::Accessor.new(
      project_root: root,
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
    accessor, root, issues = build_env(dir)
    out = StringIO.new

    When "creating a plan"
    accessor.run(["new", "Carve system"], out: out)

    Then "the issue body is the H1 plus dev's bundled template, and the file is linked"
    issues.get(REPO, 1).body.start_with?("# Carve system\n")
    issues.get(REPO, 1).body.include?("## Problem / Opportunity")
    issues.get(REPO, 1).body.include?("## Tech design")
    header, body = read_plan(root, "gh-1-carve-system.plan.md")
    header.issue_ref == "#{REPO}#1"
    header.synced_at == issues.get(REPO, 1).updated_at
    body == issues.get(REPO, 1).body
    !out.string.include?("stale")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "new --blank creates a bare plan (no template)" do
    Given "a workspace"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)

    When "creating a blank plan"
    accessor.run(["new", "Carve system", "--blank"], out: StringIO.new)

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
    accessor, root, issues = build_env(dir)
    mirror = Dev::Plan::Templates.mirror_path(root)
    FileUtils.mkdir_p(mirror.dirname)
    mirror.write("---\nname: Custom plan\n---\n\n## Custom section\n\nRepo flavor.\n")
    out = StringIO.new

    When "creating a plan"
    accessor.run(["new", "Carve system"], out: out)

    Then "the repo template body is scaffolded and no staleness warning fires"
    issues.get(REPO, 1).body == "# Carve system\n\n## Custom section\n\nRepo flavor.\n"
    !out.string.include?("stale")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "new warns when the repo's mirror is stale vs dev's bundle, but still uses it" do
    Given "a marker-carrying mirror that drifted from the bundle"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    mirror = Dev::Plan::Templates.mirror_path(root)
    FileUtils.mkdir_p(mirror.dirname)
    mirror.write("---\nname: Tech design\n---\n#{Dev::Plan::Templates::MARKER}\n\n## Old template section\n")
    out = StringIO.new

    When "creating a plan"
    accessor.run(["new", "Carve system"], out: out)

    Then "the committed (stale) copy is authoritative and the warning points at dev plan init"
    issues.get(REPO, 1).body == "# Carve system\n\n## Old template section\n"
    out.string.include?("stale")
    out.string.include?("dev plan init")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "new --org fetches the plans repo template, falling back to the bundle" do
    Given "a plans repo carrying its own plan template"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, _root, issues = build_env(dir)
    issues.add_file(
      "d3mlabs/plans", ".github/ISSUE_TEMPLATE/plan.md",
      "---\nname: Org plan\n---\n\n## Org section\n",
    )

    When "creating an org-wide plan"
    accessor.run(["new", "Org roadmap", "--org"], out: StringIO.new)

    Then "the fetched template body follows the Target repos scaffold"
    issues.get("d3mlabs/plans", 1).body.include?("Target repos:")
    issues.get("d3mlabs/plans", 1).body.include?("## Org section")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "new --org targets the configured org plans repo" do
    Given "a workspace"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)

    When "creating an org-wide plan"
    accessor.run(["new", "Org roadmap", "--org"], out: StringIO.new)

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
    accessor, root, issues = build_env(dir)
    accessor.run(["new", "Carve system"], out: StringIO.new)
    path = root / ".cursor" / "plans" / "gh-1-carve-system.plan.md"
    header, _body = Dev::Plan::Header.split(path.read)
    path.write(header.render + "# Carve system\n\nNew section.\n")

    When "pushing"
    accessor.run(["push"], out: StringIO.new)

    Then "the issue body is updated and synced_at advances to the new updated_at"
    issues.get(REPO, 1).body == "# Carve system\n\nNew section.\n"
    new_header, _new_body = Dev::Plan::Header.split(path.read)
    new_header.synced_at == issues.get(REPO, 1).updated_at

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "push renames the issue when the plan's H1 title changed" do
    Given "a linked plan whose H1 was edited"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    accessor.run(["new", "Old title"], out: StringIO.new)
    path = root / ".cursor" / "plans" / "gh-1-old-title.plan.md"
    header, _body = Dev::Plan::Header.split(path.read)
    path.write(header.render + "# New title\n")

    When "pushing"
    accessor.run(["push"], out: StringIO.new)

    Then
    issues.get(REPO, 1).title == "New title"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "push by issue number resolves the linked plan like pull does" do
    Given "two linked plans with local edits on the first"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    accessor.run(["new", "Carve system", "--blank"], out: StringIO.new)
    accessor.run(["new", "Second plan", "--blank"], out: StringIO.new)
    path = root / ".cursor" / "plans" / "gh-1-carve-system.plan.md"
    header, _body = Dev::Plan::Header.split(path.read)
    path.write(header.render + "# Carve system\n\nNew section.\n")

    When "pushing by number"
    accessor.run(["push", "1"], out: StringIO.new)

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
    accessor.run(["new", "Org roadmap", "--org"], out: StringIO.new)
    path = root / ".cursor" / "plans" / "gh-plans-1-org-roadmap.plan.md"
    header, _body = Dev::Plan::Header.split(path.read)
    path.write(header.render + "# Org roadmap\n\nScoped.\n")

    When "pushing by number with --org"
    accessor.run(["push", "1", "--org"], out: StringIO.new)

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
    accessor.run(["push", "7"], out: StringIO.new)

    Then
    raises Dev::Plan::Accessor::UsageError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "push refuses when the remote body changed since the last sync" do
    Given "a linked plan whose issue was edited remotely"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    accessor.run(["new", "Carve system"], out: StringIO.new)
    issues.edit_remotely(REPO, 1, body: "# Carve system\n\nRemote addition.\n")
    path = root / ".cursor" / "plans" / "gh-1-carve-system.plan.md"
    header, _body = Dev::Plan::Header.split(path.read)
    path.write(header.render + "# Carve system\n\nLocal addition.\n")

    When "pushing"
    accessor.run(["push"], out: StringIO.new)

    Then "the guard rejects the clobber"
    raises RuntimeError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "pull overwrites a clean local copy with remote edits" do
    Given "a clean linked plan whose issue moved ahead"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    accessor.run(["new", "Carve system"], out: StringIO.new)
    issues.edit_remotely(REPO, 1, body: "# Carve system\n\nRemote addition.\n")

    When "pulling"
    accessor.run(["pull", "1"], out: StringIO.new)

    Then "the local body matches the remote and synced_at advances"
    header, body = read_plan(root, "gh-1-carve-system.plan.md")
    body == "# Carve system\n\nRemote addition.\n"
    header.synced_at == issues.get(REPO, 1).updated_at

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "pull creates the local plan when none exists (load issue as plan)" do
    Given "an issue with no local copy"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    issues.create(REPO, title: "Remote-born plan", body: "# Remote-born plan\n")

    When "pulling it"
    accessor.run(["pull", "1"], out: StringIO.new)

    Then "a linked plan file materializes"
    header, body = read_plan(root, "gh-1-remote-born-plan.plan.md")
    header.issue_ref == "#{REPO}#1"
    body == "# Remote-born plan\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "pull without --merge refuses when both sides changed" do
    Given "a diverged plan"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    accessor.run(["new", "Carve system"], out: StringIO.new)
    issues.edit_remotely(REPO, 1, body: "# Carve system\n\nRemote addition.\n")
    path = root / ".cursor" / "plans" / "gh-1-carve-system.plan.md"
    header, _body = Dev::Plan::Header.split(path.read)
    path.write(header.render + "# Carve system\n\nLocal addition.\n")

    When "pulling without --merge"
    accessor.run(["pull", "1"], out: StringIO.new)

    Then
    raises RuntimeError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "pull --merge integrates non-overlapping edits from both sides" do
    Given "a diverged plan with non-overlapping edits"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    base = "# Plan\n\nalpha\n\none\ntwo\nthree\nfour\n\nomega\n"
    issues.create(REPO, title: "Plan", body: "#{base}\n")
    accessor.run(["pull", "1"], out: StringIO.new)
    issues.edit_remotely(REPO, 1, body: "#{base.sub("omega", "omega REMOTE")}\n")
    path = root / ".cursor" / "plans" / "gh-1-plan.plan.md"
    header, _body = Dev::Plan::Header.split(path.read)
    path.write(header.render + base.sub("alpha", "alpha LOCAL"))

    When "pulling with --merge, then pushing the merged result"
    accessor.run(["pull", "1", "--merge"], out: StringIO.new)
    accessor.run(["push"], out: StringIO.new)

    Then "both edits are in the issue"
    issues.get(REPO, 1).body == base.sub("alpha", "alpha LOCAL").sub("omega", "omega REMOTE")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "push refuses while the file holds unresolved conflict markers" do
    Given "a merge that conflicted"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    accessor.run(["new", "Plan"], out: StringIO.new)
    issues.edit_remotely(REPO, 1, body: "# Plan remote\n")
    path = root / ".cursor" / "plans" / "gh-1-plan.plan.md"
    header, _body = Dev::Plan::Header.split(path.read)
    path.write(header.render + "# Plan local\n")
    accessor.run(["pull", "1", "--merge"], out: StringIO.new)

    When "pushing without resolving the markers"
    accessor.run(["push"], out: StringIO.new)

    Then
    raises RuntimeError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "link <n> attaches an existing draft to an issue, keeping local content" do
    Given "an unlinked draft and an existing issue"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    issues.create(REPO, title: "Existing issue", body: "# Existing issue\n")
    draft = root / ".cursor" / "plans" / "draft.plan.md"
    FileUtils.mkdir_p(draft.dirname)
    draft.write("# My draft\n\nLocal thinking.\n")

    When "linking the draft to issue 1 and pushing"
    accessor.run(["link", "1", draft.to_s], out: StringIO.new)
    accessor.run(["push"], out: StringIO.new)

    Then "the draft moved to the conventional name and its content is published"
    !draft.exist?
    header, _body = read_plan(root, "gh-1-existing-issue.plan.md")
    header.issue_ref == "#{REPO}#1"
    issues.get(REPO, 1).body == "# My draft\n\nLocal thinking.\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "link <file> creates a new issue from the draft (canonize)" do
    Given "an unlinked draft"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    draft = root / ".cursor" / "plans" / "draft.plan.md"
    FileUtils.mkdir_p(draft.dirname)
    draft.write("# Fresh plan\n\nContent.\n")

    When "canonizing it"
    accessor.run(["link", draft.to_s], out: StringIO.new)

    Then "the issue is created from the H1 title with the draft's body"
    issues.get(REPO, 1).title == "Fresh plan"
    issues.get(REPO, 1).body == "# Fresh plan\n\nContent.\n"
    header, _body = read_plan(root, "gh-1-fresh-plan.plan.md")
    header.issue_ref == "#{REPO}#1"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "status reports clean, ahead, behind, and diverged plans" do
    Given "four linked plans in each sync state"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    accessor.run(["new", "Clean plan"], out: StringIO.new)
    accessor.run(["new", "Ahead plan"], out: StringIO.new)
    accessor.run(["new", "Behind plan"], out: StringIO.new)
    accessor.run(["new", "Diverged plan"], out: StringIO.new)
    plans = root / ".cursor" / "plans"
    [["gh-2-ahead-plan.plan.md", 2], ["gh-4-diverged-plan.plan.md", 4]].each do |name, _n|
      path = plans / name
      header, body = Dev::Plan::Header.split(path.read)
      path.write(header.render + body + "\nlocal edit\n")
    end
    issues.edit_remotely(REPO, 3, body: "# Behind plan\n\nremote edit\n")
    issues.edit_remotely(REPO, 4, body: "# Diverged plan\n\nremote edit\n")
    out = StringIO.new

    When "listing status"
    accessor.run(["status"], out: out)

    Then "each plan reports its state"
    out.string.match?(/^clean\s+#{REPO}#1/)
    out.string.match?(/^ahead\s+#{REPO}#2/)
    out.string.match?(/^behind\s+#{REPO}#3/)
    out.string.match?(/^diverged\s+#{REPO}#4/)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "hook-after-edit auto-pushes an edited linked plan" do
    Given "a linked plan with fresh local edits, as the afterFileEdit hook sees it"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)
    accessor.run(["new", "Carve system"], out: StringIO.new)
    path = root / ".cursor" / "plans" / "gh-1-carve-system.plan.md"
    header, _body = Dev::Plan::Header.split(path.read)
    path.write(header.render + "# Carve system\n\nAgent edit.\n")
    payload = StringIO.new(JSON.generate(file_path: path.to_s))

    When "the hook fires"
    accessor.run(["hook-after-edit"], out: StringIO.new, input: payload)

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
    accessor.run(["hook-after-edit"], out: StringIO.new, input: StringIO.new(JSON.generate(file_path: draft.to_s)))
    accessor.run(["hook-after-edit"], out: StringIO.new, input: StringIO.new(JSON.generate(file_path: source.to_s)))

    Then "nothing raises and nothing syncs (no issues exist to sync to)"
    draft.read == "# Draft\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an unknown subcommand raises UsageError" do
    Given "an accessor"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, _root, _issues = build_env(dir)

    When "running an unrecognized subcommand"
    accessor.run(["sync"], out: StringIO.new)

    Then
    raises Dev::Plan::Accessor::UsageError

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
    accessor.run(["push", draft.to_s], out: StringIO.new)

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
    accessor.run(["link", draft.to_s], out: StringIO.new)

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
    accessor.run(["new", "Carve system"], out: StringIO.new)
    path = root / ".cursor" / "plans" / "gh-1-carve-system.plan.md"
    plan = Dev::Plan::Content.parse(path.read)
    path.write(Dev::Plan::Content.new(
      header: plan.header, frontmatter: CURSOR_FRONTMATTER, body: plan.body,
    ).render)
    issues.edit_remotely(REPO, 1, body: "# Carve system\n\nRemote addition.\n")

    When "pulling"
    accessor.run(["pull", "1"], out: StringIO.new)

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
    accessor, root, issues = build_env(dir)
    accessor.run(["new", "Carve system", "--blank"], out: StringIO.new)
    path = root / ".cursor" / "plans" / "gh-1-carve-system.plan.md"
    plan = Dev::Plan::Content.parse(path.read)
    path.write(Dev::Plan::Content.new(
      header: plan.header, frontmatter: CURSOR_FRONTMATTER, body: plan.body,
    ).render)
    out = StringIO.new

    When "checking status and pushing"
    accessor.run(["status"], out: out)
    accessor.run(["push"], out: StringIO.new)

    Then "status is clean, the issue is unchanged, and frontmatter remains local"
    out.string.match?(/^clean\s+#{REPO}#1/)
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
    accessor.run(["pull", "1"], out: StringIO.new)
    path = root / ".cursor" / "plans" / "gh-1-plan.plan.md"
    plan = Dev::Plan::Content.parse(path.read)
    path.write(Dev::Plan::Content.new(
      header: plan.header,
      frontmatter: CURSOR_FRONTMATTER,
      body: base.sub("alpha", "alpha LOCAL"),
    ).render)
    issues.edit_remotely(REPO, 1, body: "#{base.sub("omega", "omega REMOTE")}\n")

    When "pulling with --merge"
    accessor.run(["pull", "1", "--merge"], out: StringIO.new)

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
    accessor, root, _issues = build_env(dir)
    out = StringIO.new

    When "running init"
    accessor.run(["init"], out: out)

    Then "the mirror is written verbatim from the bundle render"
    Dev::Plan::Templates.mirror_path(root).read == Dev::Plan::Templates.render_mirror
    out.string.include?("created")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "init is a no-op when the mirror is already up to date" do
    Given "a freshly scaffolded mirror"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, _issues = build_env(dir)
    accessor.run(["init"], out: StringIO.new)
    out = StringIO.new

    When "running init again"
    accessor.run(["init"], out: out)

    Then
    Dev::Plan::Templates.mirror_path(root).read == Dev::Plan::Templates.render_mirror
    out.string.include?("up to date")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "init updates a stale marker-carrying mirror" do
    Given "a mirror that drifted from the bundle"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, _issues = build_env(dir)
    mirror = Dev::Plan::Templates.mirror_path(root)
    FileUtils.mkdir_p(mirror.dirname)
    mirror.write("---\nname: Tech design\n---\n#{Dev::Plan::Templates::MARKER}\n\n## Old template section\n")
    out = StringIO.new

    When "running init"
    accessor.run(["init"], out: out)

    Then "the mirror is overwritten and the output points at git diff for review"
    mirror.read == Dev::Plan::Templates.render_mirror
    out.string.include?("updated")
    out.string.include?("git diff")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "init leaves a repo-owned template (no marker) untouched" do
    Given "a repo that owns its plan template"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, _issues = build_env(dir)
    mirror = Dev::Plan::Templates.mirror_path(root)
    FileUtils.mkdir_p(mirror.dirname)
    owned = "---\nname: Custom plan\n---\n\n## Custom section\n"
    mirror.write(owned)
    out = StringIO.new

    When "running init"
    accessor.run(["init"], out: out)

    Then "the file is untouched and reported as repo-owned"
    mirror.read == owned
    out.string.include?("repo-owned")

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
    accessor.run(["push", path.to_s], out: StringIO.new)

    Then "the issue is cleaned to markdown-only"
    issues.get(REPO, 1).body == "# Carve system\n"
    !issues.get(REPO, 1).body.include?("---\n")

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
