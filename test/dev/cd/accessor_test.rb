# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cd"
require "fileutils"
require "stringio"
require "tmpdir"

# A hook installer stand-in with a scripted ensure result, so accessor flows
# are tested without touching the user's real shell RC.
class FakeCdHookInstaller
  attr_reader :ensure_count

  def initialize(result: :already_present)
    @result = result
    @ensure_count = 0
  end

  def ensure_installed
    @ensure_count += 1
    @result
  end
end unless defined?(FakeCdHookInstaller)

transform!(RSpock::AST::Transformation)
class Dev::Cd::AccessorTest < Minitest::Test
  test "--resolve prints exactly the matching repo's absolute path on stdout" do
    Given "a src tree with one matching repo"
    root = Dir.mktmpdir("cd-accessor-")
    repo_dir = make_repo(root, "github.com/d3mlabs/dev")
    accessor = build_accessor(root)
    out = StringIO.new

    When "we resolve the leaf name"
    accessor.run(["--resolve", "dev"], out: out, err: StringIO.new)

    Then "stdout is the absolute path and nothing else"
    out.string == "#{File.expand_path(repo_dir)}\n"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "--resolve with no match raises RepoNotFoundError" do
    Given "an empty src tree"
    root = Dir.mktmpdir("cd-accessor-")
    accessor = build_accessor(root)

    When "we resolve an unknown name"
    accessor.run(["--resolve", "nope"], out: StringIO.new, err: StringIO.new)

    Then
    raises Dev::Cd::Matcher::RepoNotFoundError

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "--resolve with an ambiguous query raises AmbiguousRepoError" do
    Given "two repos sharing a leaf name"
    root = Dir.mktmpdir("cd-accessor-")
    make_repo(root, "github.com/d3mlabs/dev")
    make_repo(root, "github.com/someone/dev")
    accessor = build_accessor(root)

    When "we resolve the shared leaf"
    accessor.run(["--resolve", "dev"], out: StringIO.new, err: StringIO.new)

    Then
    raises Dev::Cd::Matcher::AmbiguousRepoError

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "--resolve self-heals the hook and hints at a new shell when just added" do
    Given "a repo and a hook installer that reports :added"
    root = Dir.mktmpdir("cd-accessor-")
    make_repo(root, "github.com/d3mlabs/dev")
    installer = FakeCdHookInstaller.new(result: :added)
    accessor = Dev::Cd::Accessor.new(root: root, hook_installer: installer)
    err = StringIO.new

    When "we resolve"
    accessor.run(["--resolve", "dev"], out: StringIO.new, err: err)

    Then "the hook was ensured and the hint printed to stderr"
    installer.ensure_count == 1
    assert_includes err.string, "open a new shell"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "--resolve stays quiet on stderr when the hook was already present" do
    Given "a repo and an already-installed hook"
    root = Dir.mktmpdir("cd-accessor-")
    make_repo(root, "github.com/d3mlabs/dev")
    accessor = build_accessor(root)
    err = StringIO.new

    When "we resolve"
    accessor.run(["--resolve", "dev"], out: StringIO.new, err: err)

    Then "no hint is printed"
    err.string == ""

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "--resolve without exactly one query raises UsageError" do
    Given "an accessor"
    accessor = build_accessor(Dir.tmpdir)

    When "we resolve with no query"
    accessor.run(["--resolve"], out: StringIO.new, err: StringIO.new)

    Then
    raises Dev::Cd::Accessor::UsageError
  end

  test "--candidates prints ranked candidates one per line" do
    Given "a tree with two repos matching the partial query"
    root = Dir.mktmpdir("cd-accessor-")
    make_repo(root, "github.com/d3mlabs/dev")
    make_repo(root, "github.com/d3mlabs/devkit")
    make_repo(root, "github.com/d3mlabs/ai-flow")
    accessor = build_accessor(root)
    out = StringIO.new

    When "we ask for candidates"
    accessor.run(["--candidates", "dev"], out: out, err: StringIO.new)

    Then "matches come back ranked, one per line"
    out.string == "dev\ndevkit\n"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "--candidates with an empty query lists everything" do
    Given "a tree with two repos"
    root = Dir.mktmpdir("cd-accessor-")
    make_repo(root, "github.com/d3mlabs/dev")
    make_repo(root, "github.com/d3mlabs/ai-flow")
    accessor = build_accessor(root)
    out = StringIO.new

    When "we ask for candidates with no argument"
    accessor.run(["--candidates"], out: out, err: StringIO.new)

    Then "every repo is listed"
    out.string.split("\n").sort == ["ai-flow", "dev"]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "--candidates disambiguates duplicate leaves as org/repo" do
    Given "two repos sharing a leaf name"
    root = Dir.mktmpdir("cd-accessor-")
    make_repo(root, "github.com/d3mlabs/dev")
    make_repo(root, "github.com/someone/dev")
    accessor = build_accessor(root)
    out = StringIO.new

    When "we ask for candidates"
    accessor.run(["--candidates", "dev"], out: out, err: StringIO.new)

    Then "each candidate carries its org"
    out.string.split("\n").sort == ["d3mlabs/dev", "someone/dev"]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "bare dev cd raises ShellHookInactiveError after ensuring the hook" do
    Given "an accessor whose hook is already installed"
    installer = FakeCdHookInstaller.new(result: :already_present)
    accessor = Dev::Cd::Accessor.new(root: Dir.tmpdir, hook_installer: installer)
    err = StringIO.new

    When "we run without plumbing flags"
    accessor.run(["dev"], out: StringIO.new, err: err)

    Then "the hook was ensured and the activation hint printed"
    raises Dev::Cd::Accessor::ShellHookInactiveError
    installer.ensure_count == 1
    assert_includes err.string, "not active in this shell"
  end

  test "bare dev cd on an unsupported shell explains the supported set" do
    Given "an accessor whose hook install is refused"
    installer = FakeCdHookInstaller.new(result: false)
    accessor = Dev::Cd::Accessor.new(root: Dir.tmpdir, hook_installer: installer)
    err = StringIO.new

    When "we run without plumbing flags"
    accessor.run([], out: StringIO.new, err: err)

    Then "the supported shells are named"
    raises Dev::Cd::Accessor::ShellHookInactiveError
    assert_includes err.string, "zsh, bash, fish"
  end

  private

  def build_accessor(root)
    Dev::Cd::Accessor.new(root: root, hook_installer: FakeCdHookInstaller.new)
  end

  def make_repo(root, relative_path)
    dir = File.join(root, relative_path)
    FileUtils.mkdir_p(File.join(dir, ".git"))
    dir
  end
end
