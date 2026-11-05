# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::GitTest < Minitest::Test
  test "capture returns what git printed, run inside the root with the env added" do
    Given "an initialised repository"
    root = Pathname(Dir.mktmpdir("lifecycle-git-"))
    git = Dev::Lifecycle::Git.new(root:)
    git.capture(["init", "-q"])

    When "asking git something that reads the env"
    out = git.capture(["var", "GIT_AUTHOR_IDENT"], env: { "GIT_AUTHOR_NAME" => "snap", "GIT_AUTHOR_EMAIL" => "s@d" })

    Then
    out.start_with?("snap <s@d>")
    git.capture(["rev-parse", "--is-inside-work-tree"]).strip == "true"
    git.root == root

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a failing command is a CommandFailedError carrying the argv and git's stderr" do
    Given "a plain directory"
    root = Pathname(Dir.mktmpdir("lifecycle-git-"))

    When
    Dev::Lifecycle::Git.new(root:).capture(["rev-parse", "HEAD"])

    Then
    error = raises(Dev::Lifecycle::Git::CommandFailedError)
    error.message.include?("git rev-parse HEAD failed in #{root}")
    error.message.include?("not a git repository")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "no git on PATH is a GitMissingError, from either call" do
    Given "a PATH with nothing on it"
    root = Pathname(Dir.mktmpdir("lifecycle-git-"))
    path_before = ENV.fetch("PATH")
    ENV["PATH"] = root.to_s
    git = Dev::Lifecycle::Git.new(root:)

    When
    git.capture(["--version"])

    Then
    raises(Dev::Lifecycle::Git::GitMissingError)

    Cleanup
    ENV["PATH"] = path_before
    FileUtils.rm_rf(root)
  end

  test "succeeds? without git on PATH is a GitMissingError too" do
    Given "a PATH with nothing on it"
    root = Pathname(Dir.mktmpdir("lifecycle-git-"))
    path_before = ENV.fetch("PATH")
    ENV["PATH"] = root.to_s
    git = Dev::Lifecycle::Git.new(root:)

    When
    git.succeeds?(["--version"])

    Then
    raises(Dev::Lifecycle::Git::GitMissingError)

    Cleanup
    ENV["PATH"] = path_before
    FileUtils.rm_rf(root)
  end

  test "succeeds? answers the exit code without raising" do
    Given "a repository with no commit"
    root = Pathname(Dir.mktmpdir("lifecycle-git-"))
    git = Dev::Lifecycle::Git.new(root:)
    git.capture(["init", "-q"])

    Expect
    git.succeeds?(["rev-parse", "--git-dir"])
    !git.succeeds?(["rev-parse", "--verify", "--quiet", "HEAD"])

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "git never prompts: the terminal prompt is disabled for every call" do
    Given "a repository"
    root = Pathname(Dir.mktmpdir("lifecycle-git-"))
    git = Dev::Lifecycle::Git.new(root:)
    git.capture(["init", "-q"])

    Expect "the variable git reads is set for the child"
    git.capture(["-c", "alias.showenv=!printenv GIT_TERMINAL_PROMPT", "showenv"]).strip == "0"

    Cleanup
    FileUtils.rm_rf(root)
  end
end
