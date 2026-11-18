# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::JobCheckoutTest < Minitest::Test
  test "inside an Actions job, a clean checkout at GITHUB_SHA is a snapshot at GITHUB_REF with no branch" do
    Given
    root = checkout
    head = git(root).capture(["rev-parse", "HEAD"]).strip
    env = { "GITHUB_ACTIONS" => "true", "GITHUB_SHA" => head, "GITHUB_REF" => "refs/pull/338/merge" }

    When
    snapshot = Dev::Lifecycle::JobCheckout.new(git: git(root), env:).snapshot

    Then
    snapshot == Dev::Lifecycle::Snapshot.checked_out(sha: head, ref: "refs/pull/338/merge")
    snapshot.branch.nil?
    !snapshot.pushed?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "outside a job, or when the job's facts are missing, there is no checkout snapshot: #{label}" do
    Given
    root = checkout
    head = git(root).capture(["rev-parse", "HEAD"]).strip
    env = env_for.call(head)

    Expect
    Dev::Lifecycle::JobCheckout.new(git: git(root), env:).snapshot.nil?

    Cleanup
    FileUtils.rm_rf(root)

    Where
    label              | env_for
    "no marker"        | ->(sha) { { "GITHUB_SHA" => sha, "GITHUB_REF" => "refs/heads/main" } }
    "no GITHUB_SHA"    | ->(_sha) { { "GITHUB_ACTIONS" => "true", "GITHUB_REF" => "refs/heads/main" } }
    "no GITHUB_REF"    | ->(sha) { { "GITHUB_ACTIONS" => "true", "GITHUB_SHA" => sha } }
    "HEAD elsewhere"   | ->(_sha) { { "GITHUB_ACTIONS" => "true", "GITHUB_SHA" => "0" * 40, "GITHUB_REF" => "refs/heads/main" } }
  end

  test "a job checkout with changes is not the forge's tree: no snapshot, and the reason names the paths" do
    Given "a tracked edit and an untracked file"
    root = checkout
    head = git(root).capture(["rev-parse", "HEAD"]).strip
    (root / "a.txt").write("changed\n")
    (root / "new.txt").write("new\n")
    env = { "GITHUB_ACTIONS" => "true", "GITHUB_SHA" => head, "GITHUB_REF" => "refs/heads/main" }
    job = Dev::Lifecycle::JobCheckout.new(git: git(root), env:)

    Expect
    job.snapshot.nil?
    job.reason.include?("M a.txt")
    job.reason.include?("?? new.txt")

    Cleanup
    FileUtils.rm_rf(root)
  end

  def checkout
    root = Pathname(Dir.mktmpdir("job-checkout-"))
    g = git(root)
    g.capture(["init", "-q", "-b", "main"])
    (root / "a.txt").write("a\n")
    g.capture(["add", "a.txt"])
    g.capture(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "one"])
    root
  end

  def git(root)
    Dev::Lifecycle::Git.new(root:)
  end
end
