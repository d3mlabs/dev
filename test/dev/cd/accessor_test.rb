# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cd"
require "fileutils"
require "stringio"
require "tmpdir"

# A hook installer stand-in with a scripted RC state, so accessor flows are
# tested without touching the user's real shell RC. Subclasses the real
# installer so the accessor's typed constructor accepts it.
#
# `installed_before:` is what the RC carries before the ensure; the ensure
# installs unless the run is headless (off a tty the real installer writes
# nothing). An unsupported shell refuses both the ensure and the query.
class FakeCdHookInstaller < Dev::Cd::HookInstaller
  UNSUPPORTED_SHELL_MESSAGE = "/bin/sh is not a supported shell (supported: zsh, bash, fish)"

  attr_reader :ensure_count

  def initialize(installed_before: true, interactive: true, shell_supported: true)
    @installed = installed_before
    @interactive = interactive
    @shell_supported = shell_supported
    @ensure_count = 0
  end

  def ensure_installed
    @ensure_count += 1
    refuse_unsupported_shell
    @installed = true if @interactive
  end

  def installed?
    refuse_unsupported_shell
    @installed
  end

  private

  def refuse_unsupported_shell
    raise Dev::ShellRcHook::UnsupportedShellError, UNSUPPORTED_SHELL_MESSAGE unless @shell_supported
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
    accessor.resolve("dev", out: out, err: StringIO.new)

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
    accessor.resolve("nope", out: StringIO.new, err: StringIO.new)

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
    accessor.resolve("dev", out: StringIO.new, err: StringIO.new)

    Then
    raises Dev::Cd::Matcher::AmbiguousRepoError

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "--resolve self-heals a stale hook and hints at a new shell" do
    Given "a repo and an RC without the current hook generation"
    root = Dir.mktmpdir("cd-accessor-")
    make_repo(root, "github.com/d3mlabs/dev")
    installer = FakeCdHookInstaller.new(installed_before: false)
    accessor = Dev::Cd::Accessor.new(root: root, hook_installer: installer)
    err = StringIO.new

    When "we resolve"
    accessor.resolve("dev", out: StringIO.new, err: err)

    Then "the hook was ensured and the hint printed to stderr"
    installer.ensure_count == 1
    installer.installed?
    assert_includes err.string, "open a new shell"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "--resolve stays quiet on stderr when the hook is current" do
    Given "a repo and an already-installed hook"
    root = Dir.mktmpdir("cd-accessor-")
    make_repo(root, "github.com/d3mlabs/dev")
    accessor = build_accessor(root)
    err = StringIO.new

    When "we resolve"
    accessor.resolve("dev", out: StringIO.new, err: err)

    Then "no hint is printed"
    err.string == ""

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "--resolve off a tty with a stale hook prints no refresh hint: nothing was written" do
    Given "a repo, a stale RC, and a headless run"
    root = Dir.mktmpdir("cd-accessor-")
    make_repo(root, "github.com/d3mlabs/dev")
    installer = FakeCdHookInstaller.new(installed_before: false, interactive: false)
    accessor = Dev::Cd::Accessor.new(root: root, hook_installer: installer)
    err = StringIO.new

    When "we resolve"
    accessor.resolve("dev", out: StringIO.new, err: err)

    Then "no hint is printed"
    err.string == ""

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "--resolve on an unsupported $SHELL still prints the path: the self-heal never blocks the cd" do
    Given "a repo and a refusing hook installer"
    root = Dir.mktmpdir("cd-accessor-")
    repo_dir = make_repo(root, "github.com/d3mlabs/dev")
    accessor = Dev::Cd::Accessor.new(root: root, hook_installer: FakeCdHookInstaller.new(shell_supported: false))
    out = StringIO.new
    err = StringIO.new

    When "we resolve"
    accessor.resolve("dev", out: out, err: err)

    Then "stdout is the path and stderr stays quiet"
    out.string == "#{File.expand_path(repo_dir)}\n"
    err.string == ""

    Cleanup
    FileUtils.rm_rf(root)
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
    accessor.candidates("dev", out: out)

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
    accessor.candidates("", out: out)

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
    accessor.candidates("dev", out: out)

    Then "each candidate carries its org"
    out.string.split("\n").sort == ["d3mlabs/dev", "someone/dev"]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "bare dev cd raises ShellHookInactiveError after ensuring the hook" do
    Given "an accessor whose hook is already installed"
    installer = FakeCdHookInstaller.new(installed_before: true)
    accessor = Dev::Cd::Accessor.new(root: Dir.tmpdir, hook_installer: installer)
    err = StringIO.new

    When "we explain the missing hook"
    accessor.explain_missing_hook(err: err)

    Then "the hook was ensured and the activation hint printed"
    raises Dev::Cd::Accessor::ShellHookInactiveError
    installer.ensure_count == 1
    assert_includes err.string, "installed but not active in this shell"
    assert_includes err.string, "open a new shell"
  end

  test "bare dev cd that just installed the hook gives the same activation hint" do
    Given "an accessor whose RC lacked the hook"
    installer = FakeCdHookInstaller.new(installed_before: false)
    accessor = Dev::Cd::Accessor.new(root: Dir.tmpdir, hook_installer: installer)
    err = StringIO.new

    When "we explain the missing hook"
    accessor.explain_missing_hook(err: err)

    Then "the hook is now installed and the one activation hint is printed"
    raises Dev::Cd::Accessor::ShellHookInactiveError
    installer.installed?
    assert_includes err.string, "installed but not active in this shell"
    assert_includes err.string, "open a new shell"
  end

  test "bare dev cd off a tty says no hook was installed, not that the shell is unsupported" do
    Given "an accessor whose hook install writes nothing (headless)"
    installer = FakeCdHookInstaller.new(installed_before: false, interactive: false)
    accessor = Dev::Cd::Accessor.new(root: Dir.tmpdir, hook_installer: installer)
    err = StringIO.new

    When "we explain the missing hook"
    accessor.explain_missing_hook(err: err)

    Then "the headless posture is named, the shell is not blamed"
    raises Dev::Cd::Accessor::ShellHookInactiveError
    assert_includes err.string, "not an interactive terminal"
    !err.string.include?("supported")
  end

  test "bare dev cd on an unsupported shell explains the supported set" do
    Given "an accessor whose hook install is refused"
    installer = FakeCdHookInstaller.new(shell_supported: false)
    accessor = Dev::Cd::Accessor.new(root: Dir.tmpdir, hook_installer: installer)
    err = StringIO.new

    When "we explain the missing hook"
    accessor.explain_missing_hook(err: err)

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
