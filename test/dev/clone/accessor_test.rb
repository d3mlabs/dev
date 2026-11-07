# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/clone"
require "fileutils"
require "stringio"
require "tmpdir"

# A cloner stand-in recording its calls, so accessor flows are tested without
# gh or the network. Subclasses the real cloner so the accessor's typed
# constructor accepts it.
class FakeGhCloner < Dev::Clone::GhCloner
  attr_reader :calls

  def initialize
    @calls = []
  end

  def clone(full_name, destination)
    @calls << [full_name, destination.to_s]
  end
end unless defined?(FakeGhCloner)

# A hook installer stand-in with a scripted RC state, so accessor flows are
# tested without touching the user's real shell RC. Subclasses the real
# installer so the accessor's typed constructor accepts it.
#
# `installed_before:` is what the RC carries before the ensure; the ensure
# installs unless the run is headless (off a tty the real installer writes
# nothing). An unsupported shell refuses both the ensure and the query.
class FakeCloneHookInstaller < Dev::Cd::HookInstaller
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
end unless defined?(FakeCloneHookInstaller)

transform!(RSpock::AST::Transformation)
class Dev::Clone::AccessorTest < Minitest::Test
  test "--path clones and prints exactly the destination's absolute path on stdout" do
    Given "an empty checkout root"
    root = Dir.mktmpdir("clone-accessor-")
    cloner = FakeGhCloner.new
    installer = FakeCloneHookInstaller.new
    accessor = build_accessor(root, cloner: cloner, hook_installer: installer)
    out = StringIO.new
    err = StringIO.new

    When "we clone via the wrapper's plumbing mode"
    accessor.run("acme/widget", plumbing: true, out: out, err: err)

    Then "the clone landed at the canonical path, printed as the only stdout line"
    expected = File.join(File.expand_path(root), "github.com", "acme", "widget")
    cloner.calls == [["acme/widget", expected]]
    out.string == "#{expected}\n"
    err.string == ""
    installer.ensure_count == 0

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a bare repo name expands under the configured default org" do
    Given "an empty checkout root and default_org: d3mlabs in settings"
    root = Dir.mktmpdir("clone-accessor-")
    cloner = FakeGhCloner.new
    accessor = build_accessor(root, cloner: cloner)

    When "we clone by leaf name"
    accessor.run("dev", plumbing: true, out: StringIO.new, err: StringIO.new)

    Then "the clone targets d3mlabs/dev at the canonical path"
    cloner.calls == [["d3mlabs/dev", File.join(File.expand_path(root), "github.com", "d3mlabs", "dev")]]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a bare repo name with no default org surfaces RepoSpec's typed error" do
    Given "settings without a default_org key (and no ENV override in play)"
    root = Dir.mktmpdir("clone-accessor-")
    cloner = FakeGhCloner.new
    accessor = build_accessor(root, cloner: cloner, default_org: nil)
    saved_env = ENV.delete("DEV_DEFAULT_ORG")

    When "we clone by leaf name"
    error = assert_raises(Dev::Clone::RepoSpec::MissingDefaultOrgError) do
      accessor.run("dev", plumbing: true, out: StringIO.new, err: StringIO.new)
    end

    Then "the remediation names the settings key and no clone ran"
    assert_includes error.message, "default_org"
    cloner.calls == []

    Cleanup
    ENV["DEV_DEFAULT_ORG"] = saved_env if saved_env
    FileUtils.rm_rf(root)
  end

  test "a bare invocation still clones, keeps stdout empty, and explains the destination" do
    Given "an empty checkout root and an installed-but-inactive hook"
    root = Dir.mktmpdir("clone-accessor-")
    cloner = FakeGhCloner.new
    installer = FakeCloneHookInstaller.new(installed_before: true)
    accessor = build_accessor(root, cloner: cloner, hook_installer: installer)
    out = StringIO.new
    err = StringIO.new

    When "we clone without the wrapper"
    accessor.run("d3mlabs/dev", plumbing: false, out: out, err: err)

    Then "the clone happened, the hook was ensured, and stderr carries the story"
    cloner.calls.size == 1
    out.string == ""
    installer.ensure_count == 1
    assert_includes err.string, "cloned d3mlabs/dev to"
    assert_includes err.string, "not active in this shell"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a bare invocation that just installed the hook gives the same activation hint, with the cd" do
    Given "a hook installer over an RC without the hook"
    root = Dir.mktmpdir("clone-accessor-")
    installer = FakeCloneHookInstaller.new(installed_before: false)
    accessor = build_accessor(root, hook_installer: installer)
    err = StringIO.new

    When "we clone without the wrapper"
    accessor.run("dev", plumbing: false, out: StringIO.new, err: err)

    Then "the hook is now installed and the one activation hint is printed"
    installer.installed?
    assert_includes err.string, "installed but not active in this shell"
    assert_includes err.string, "open a new shell"
    assert_includes err.string, "For now: cd #{File.join(root, "github.com", "d3mlabs", "dev")}"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a bare invocation off a tty says no hook was installed and gives the cd" do
    Given "a hook installer whose ensure writes nothing (headless)"
    root = Dir.mktmpdir("clone-accessor-")
    accessor = build_accessor(root, hook_installer: FakeCloneHookInstaller.new(installed_before: false, interactive: false))
    err = StringIO.new

    When "we clone without the wrapper"
    accessor.run("dev", plumbing: false, out: StringIO.new, err: err)

    Then "the headless posture is named, with the cd, and the shell is not blamed"
    assert_includes err.string, "not an interactive terminal"
    assert_includes err.string, "cd #{File.join(root, "github.com", "d3mlabs", "dev")}"
    !err.string.include?("supported")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a bare invocation on an unsupported shell names the supported set and gives the cd" do
    Given "a hook installer that refuses"
    root = Dir.mktmpdir("clone-accessor-")
    accessor = build_accessor(root, hook_installer: FakeCloneHookInstaller.new(shell_supported: false))
    err = StringIO.new

    When "we clone without the wrapper"
    accessor.run("dev", plumbing: false, out: StringIO.new, err: err)

    Then "the supported shells are named and the clone is not lost"
    assert_includes err.string, "zsh, bash, fish"
    assert_includes err.string, "cd #{File.join(root, "github.com", "d3mlabs", "dev")}"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "an existing destination raises DestinationExistsError without cloning" do
    Given "the canonical path already checked out"
    root = Dir.mktmpdir("clone-accessor-")
    FileUtils.mkdir_p(File.join(root, "github.com", "d3mlabs", "dev"))
    cloner = FakeGhCloner.new
    accessor = build_accessor(root, cloner: cloner)

    When "we clone the same repo"
    error = assert_raises(Dev::Clone::Accessor::DestinationExistsError) do
      accessor.run("dev", plumbing: true, out: StringIO.new, err: StringIO.new)
    end

    Then "the error points at dev cd and no clone ran"
    assert_includes error.message, "dev cd dev"
    cloner.calls == []

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a malformed target surfaces RepoSpec's typed error" do
    Given "an accessor"
    accessor = build_accessor(Dir.tmpdir)

    When "we clone a nonsense target"
    accessor.run("a/b/c", plumbing: false, out: StringIO.new, err: StringIO.new)

    Then
    raises Dev::Clone::RepoSpec::MalformedRepoError
  end

  private

  # Real Settings over a throwaway config file (no filesystem mocks): the
  # default_org tests exercise the same read path production uses.
  def build_accessor(root, cloner: FakeGhCloner.new, hook_installer: FakeCloneHookInstaller.new,
    default_org: "d3mlabs")
    # Both layers pinned under the tmpdir: the machine's real system file
    # (a deployment's config.yml) may well declare a default_org.
    settings_dir = Dir.mktmpdir("clone-accessor-settings-")
    config_path = File.join(settings_dir, "config.yml")
    File.write(config_path, default_org ? "default_org: #{default_org}\n" : "")
    Dev::Clone::Accessor.new(
      root: root, cloner: cloner, hook_installer: hook_installer,
      settings: Dev::Settings.new(config_path: config_path, system_config_path: File.join(settings_dir, "system.yml")),
    )
  end
end
