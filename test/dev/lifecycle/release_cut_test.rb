# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "fileutils"
require "pathname"
require "tmpdir"

# The cut against real repositories: a checkout with a bare origin in a
# temp dir. Nothing here is worth mocking.
transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ReleaseCutTest < Minitest::Test
  CUT = Dev::Lifecycle::ReleaseCut
  TAG = Dev::Lifecycle::ReleaseTag

  def setup
    @workspace = Pathname(Dir.mktmpdir("release-cut-"))
    @origin = @workspace / "origin.git"
    @root = @workspace / "checkout"
    Dev::Lifecycle::Git.new(root: @workspace).capture(["init", "-q", "--bare", @origin.to_s])
    @root.mkpath
    @git = Dev::Lifecycle::Git.new(root: @root)
    @git.capture(["init", "-q", "-b", "main"])
    @git.capture(["config", "user.name", "t"])
    @git.capture(["config", "user.email", "t@t"])
    (@root / "a.txt").write("a\n")
    @git.capture(["add", "a.txt"])
    @git.capture(["commit", "-q", "-m", "one"])
    @git.capture(["remote", "add", "origin", @origin.to_s])
    @git.capture(["push", "-q", "-u", "origin", "main"])
  end

  def teardown
    FileUtils.rm_rf(@workspace)
    super
  end

  def cut
    CUT.new(git: @git)
  end

  def head
    @git.capture(["rev-parse", "HEAD"]).strip
  end

  def tag_sha(name)
    @git.capture(["rev-parse", "#{name}^{commit}"]).strip
  end

  def last_message
    @git.capture(["log", "-1", "--format=%s"]).strip
  end

  def remote_refs
    Dev::Lifecycle::Git.new(root: @origin).capture(["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads/", "refs/tags/"])
      .lines.to_h { |line| line.strip.split(" ", 2) }
  end

  def commit(message)
    @git.capture(["commit", "-q", "--allow-empty", "-m", message])
  end

  def push
    @git.capture(["push", "-q", "origin", "main"])
  end

  def rewind(count)
    @git.capture(["reset", "-q", "--hard", "HEAD~#{count}"])
  end

  def remote_main
    remote_refs["refs/heads/main"]
  end

  # The four relations to origin/main, arranged without a fetch: origin
  # moves through this checkout's own pushes, then HEAD rewinds.
  def stay_in_sync
    nil
  end

  def commit_locally
    commit("local")
  end

  def fall_behind
    commit("a")
    commit("b")
    push
    rewind(2)
  end

  def diverge
    commit("a")
    push
    rewind(1)
    commit("mine")
  end

  def commit_version(version)
    (@root / "VERSION").write("#{version}\n")
    @git.capture(["add", "VERSION"])
    @git.capture(["commit", "-q", "-m", "version #{version}"])
  end

  test "a project with a VERSION file: the plan bumps it; cut! commits the bump and tags; push! publishes branch and tag" do
    Given "the version in source behind the release, and a previous tag with two commits since"
    commit_version("1.1.0")
    @git.capture(["tag", "v1.1.0"])
    @git.capture(["push", "-q", "origin", "main", "refs/tags/v1.1.0"])
    previous = head
    (@root / "b.txt").write("b\n")
    @git.capture(["add", "b.txt"])
    @git.capture(["commit", "-q", "-m", "add b"])
    before = head

    When
    plan = cut.plan(TAG.new("1.2.0"))
    cut.cut!(plan)
    cut.push!(plan)

    Then "the plan read the branch, the bump and the notes before anything moved; " \
         "one bump commit on top of the branch, tagged, both on origin; the tag's commit is what sha answers"
    plan == CUT::Plan.new(
      tag: TAG.new("1.2.0"), branch: "main", sha: before, resuming: false,
      bump: CUT::VersionBump.new(from: "1.1.0", to: "1.2.0"),
      previous: "v1.1.0", commits: ["#{before[0, 7]} add b"], drift: CUT::Drift.new(upstream: "origin/main", ahead: 1, behind: 0),
    )
    plan.notes == "#{before[0, 7]} add b"
    (@root / "VERSION").read == "1.2.0\n"
    last_message == "Bump version to 1.2.0"
    head != before
    tag_sha("v1.2.0") == head
    cut.sha(TAG.new("1.2.0")) == head
    remote_refs == { "refs/heads/main" => head, "refs/tags/v1.2.0" => head, "refs/tags/v1.1.0" => previous }
  end

  test "a gem whose Gemfile.lock mirrors VERSION gets both in the bump commit, so the tree is clean after the cut" do
    Given "a lock recording the gem at the version in source"
    (@root / "Gemfile.lock").write("PATH\n  remote: .\n  specs:\n    dev (1.1.0)\n      cli-ui (~> 2.0)\n\nGEM\n  specs:\n    cli-ui (2.7.0)\n")
    @git.capture(["add", "Gemfile.lock"])
    commit_version("1.1.0")

    When
    plan = cut.plan(TAG.new("1.2.0"))
    cut.cut!(plan)
    lock = (@root / "Gemfile.lock").read

    Then
    lock.include?("    dev (1.2.0)\n")
    !lock.include?("1.1.0")
    @git.capture(["show", "--name-only", "--format=", "HEAD"]).split == ["Gemfile.lock", "VERSION"]
    @git.capture(["status", "--porcelain"]).empty?
  end

  test "a project without a VERSION file is tagged as it is: no bump, no commit, stock notes for a first release" do
    Given
    before = head

    When
    plan = cut.plan(TAG.new("0.1.0"))
    cut.cut!(plan)
    cut.push!(plan)

    Then
    plan.bump.nil?
    !plan.resuming
    plan.previous.nil?
    plan.commits == []
    plan.notes == "Release v0.1.0."
    head == before
    tag_sha("v0.1.0") == before
    remote_refs["refs/tags/v0.1.0"] == before
  end

  test "a VERSION already at the release's version needs no bump: the commit that set it is tagged" do
    Given
    commit_version("1.2.0")

    When
    plan = cut.plan(TAG.new("1.2.0"))
    cut.cut!(plan)

    Then
    plan.bump.nil?
    last_message == "version 1.2.0"
    tag_sha("v1.2.0") == head
  end

  test "a run whose cut landed resumes: the plan says so, cut! moves nothing, push! replays idempotently" do
    Given "a cut that was tagged but never pushed"
    commit_version("1.1.0")
    first = cut.plan(TAG.new("1.2.0"))
    cut.cut!(first)
    tagged = head

    When
    plan = cut.plan(TAG.new("1.2.0"))
    cut.cut!(plan)
    cut.push!(plan)
    cut.push!(plan)

    Then "no second bump, no second tag; origin has the one cut"
    plan.resuming
    plan.bump.nil?
    plan.branch == "main"
    head == tagged
    (@root / "VERSION").read == "1.2.0\n"
    @git.capture(["log", "--oneline"]).lines.size == 3
    remote_refs == { "refs/heads/main" => tagged, "refs/tags/v1.2.0" => tagged }
  end

  test "the plan's base is the checkout as it stands, with its drift from the remote-tracking ref as last fetched — never a fetch (dev#514): #{what}" do
    Given "a checkout whose relation to origin/main is #{what}"
    send(arrange)
    origin_main_before = remote_main

    When
    plan = cut.plan(TAG.new("1.2.0"))

    Then "the base reads what the checkout has, nothing was fetched or pulled"
    plan.sha == head
    plan.drift == CUT::Drift.new(upstream: "origin/main", ahead:, behind:)
    plan.drift.to_s == described
    remote_main == origin_main_before

    Where
    what                                | arrange          | ahead | behind | described
    "in sync"                           | :stay_in_sync    | 0     | 0      | "in sync with origin/main"
    "one commit unpushed"               | :commit_locally  | 1     | 0      | "1 ahead of origin/main, unpushed"
    "two commits behind the last fetch" | :fall_behind     | 0     | 2      | "2 behind origin/main as last fetched"
    "diverged"                          | :diverge         | 1     | 1      | "1 ahead, 1 behind origin/main as last fetched"
  end

  test "a branch origin was never fetched for has no drift to read: the base says so (dev#514)" do
    Given
    @git.capture(["checkout", "-q", "-b", "1.x"])

    When
    plan = cut.plan(TAG.new("1.2.1"))

    Then
    plan.branch == "1.x"
    plan.drift == CUT::Drift.new(upstream: "origin/1.x", ahead: nil, behind: nil)
    plan.drift.to_s == "origin/1.x never fetched"
  end

  test "the cut is two steps the verb names one by one: bump! commits the version, tag! tags it; cut! is both" do
    Given
    commit_version("1.1.0")
    plan = cut.plan(TAG.new("1.2.0"))

    When
    cut.bump!(plan)
    bumped = head
    tagged_after_bump = @git.succeeds?(["rev-parse", "--verify", "--quiet", "refs/tags/v1.2.0"])
    cut.tag!(plan)

    Then "the bump was committed with nothing tagged yet; the tag then names the bump"
    last_message == "Bump version to 1.2.0"
    !tagged_after_bump
    tag_sha("v1.2.0") == bumped
  end

  test "a tag that exists on another commit is refused: that version is cut" do
    Given
    @git.capture(["tag", "v1.2.0"])
    (@root / "b.txt").write("b\n")
    @git.capture(["add", "b.txt"])
    @git.capture(["commit", "-q", "-m", "add b"])

    When
    cut.plan(TAG.new("1.2.0"))

    Then
    error = raises(CUT::TagElsewhereError)
    error.message.include?("v1.2.0 already tags")
    error.message.include?("not HEAD")
  end

  test "a dirty tree is refused before anything, with git's status" do
    Given
    (@root / "a.txt").write("changed\n")

    When
    cut.plan(TAG.new("1.2.0"))

    Then
    error = raises(CUT::DirtyTreeError)
    error.message.include?("M a.txt")
    !@git.succeeds?(["rev-parse", "--verify", "--quiet", "refs/tags/v1.2.0"])
  end

  test "a detached HEAD is refused: there is no branch to publish" do
    Given
    @git.capture(["checkout", "-q", "--detach"])

    When
    cut.plan(TAG.new("1.2.0"))

    Then
    raises(CUT::DetachedHeadError)
  end

  test "a directory that is not a checkout with a commit is refused" do
    Given
    bare = @workspace / "empty"
    bare.mkpath

    When
    CUT.new(git: Dev::Lifecycle::Git.new(root: bare)).plan(TAG.new("1.2.0"))

    Then
    raises(CUT::NotACheckoutError)
  end

  test "a push the remote refuses is git's own failure, and the local cut stays for the retry" do
    Given
    FileUtils.rm_rf(@origin)
    plan = cut.plan(TAG.new("0.1.0"))
    cut.cut!(plan)

    When
    cut.push!(plan)

    Then
    raises(Dev::Lifecycle::Git::CommandFailedError)
    tag_sha("v0.1.0") == head
  end
end
