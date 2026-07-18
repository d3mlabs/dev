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
    @next_number = 1
    @clock = 0
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
      skill_installer: Dev::Plan::SkillInstaller.new(
        skill_source: File.join(dir, "no-skill"), skills_dir: File.join(dir, "skills"),
      ),
    )
    [accessor, root, issues]
  end

  def read_plan(root, name)
    Dev::Plan::Header.split((root / ".cursor" / "plans" / name).read)
  end

  test "new creates the issue and a linked local plan" do
    Given "a workspace"
    dir = Dir.mktmpdir("ai-flow-acc-test-")
    accessor, root, issues = build_env(dir)

    When "creating a plan"
    accessor.run(["new", "Carve system"], out: StringIO.new)

    Then "the issue carries the plan body and the file is linked to it"
    issues.get(REPO, 1).body == "# Carve system\n"
    header, body = read_plan(root, "gh-1-carve-system.plan.md")
    header.issue_ref == "#{REPO}#1"
    header.synced_at == issues.get(REPO, 1).updated_at
    body == "# Carve system\n"

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
end
