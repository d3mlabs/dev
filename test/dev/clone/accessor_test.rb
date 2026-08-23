# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/clone"
require "fileutils"
require "stringio"
require "tmpdir"

# A cloner stand-in recording its calls, so accessor flows are tested without
# gh or the network.
class FakeGhCloner
  attr_reader :calls

  def initialize
    @calls = []
  end

  def clone(full_name, destination)
    @calls << [full_name, destination.to_s]
  end
end unless defined?(FakeGhCloner)

# A hook installer stand-in with a scripted ensure result, so accessor flows
# are tested without touching the user's real shell RC.
class FakeCloneHookInstaller
  attr_reader :ensure_count

  def initialize(result: :already_present)
    @result = result
    @ensure_count = 0
  end

  def ensure_installed
    @ensure_count += 1
    @result
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
    accessor.run(["--path", "acme/widget"], out: out, err: err)

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
    accessor.run(["--path", "dev"], out: StringIO.new, err: StringIO.new)

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
      accessor.run(["--path", "dev"], out: StringIO.new, err: StringIO.new)
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
    installer = FakeCloneHookInstaller.new(result: :already_present)
    accessor = build_accessor(root, cloner: cloner, hook_installer: installer)
    out = StringIO.new
    err = StringIO.new

    When "we clone without the wrapper"
    accessor.run(["d3mlabs/dev"], out: out, err: err)

    Then "the clone happened, the hook was ensured, and stderr carries the story"
    cloner.calls.size == 1
    out.string == ""
    installer.ensure_count == 1
    assert_includes err.string, "cloned d3mlabs/dev to"
    assert_includes err.string, "not active in this shell"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a bare invocation that just installed the hook hints at a new shell" do
    Given "a hook installer that reports :added"
    root = Dir.mktmpdir("clone-accessor-")
    accessor = build_accessor(root, hook_installer: FakeCloneHookInstaller.new(result: :added))
    err = StringIO.new

    When "we clone without the wrapper"
    accessor.run(["dev"], out: StringIO.new, err: err)

    Then "the fresh-install hint is printed"
    assert_includes err.string, "shell hook installed"
    assert_includes err.string, "open a new shell"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a bare invocation on an unsupported shell names the supported set" do
    Given "a hook installer that refuses"
    root = Dir.mktmpdir("clone-accessor-")
    accessor = build_accessor(root, hook_installer: FakeCloneHookInstaller.new(result: false))
    err = StringIO.new

    When "we clone without the wrapper"
    accessor.run(["dev"], out: StringIO.new, err: err)

    Then "the supported shells are named"
    assert_includes err.string, "zsh, bash, fish"

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
      accessor.run(["--path", "dev"], out: StringIO.new, err: StringIO.new)
    end

    Then "the error points at dev cd and no clone ran"
    assert_includes error.message, "dev cd dev"
    cloner.calls == []

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "#{description} raises UsageError" do
    Given "an accessor"
    accessor = build_accessor(Dir.tmpdir)

    When "we run it"
    accessor.run(args, out: StringIO.new, err: StringIO.new)

    Then
    raises Dev::Clone::Accessor::UsageError

    Where
    args                 | description
    []                   | "no target"
    ["a", "b"]           | "two targets"
    ["--path"]           | "plumbing with no target"
    ["--path", "a", "b"] | "plumbing with two targets"
  end

  test "a malformed target surfaces RepoSpec's typed error" do
    Given "an accessor"
    accessor = build_accessor(Dir.tmpdir)

    When "we clone a nonsense target"
    accessor.run(["a/b/c"], out: StringIO.new, err: StringIO.new)

    Then
    raises Dev::Clone::RepoSpec::MalformedRepoError
  end

  private

  # Real Settings over a throwaway config file (no filesystem mocks): the
  # default_org tests exercise the same read path production uses.
  def build_accessor(root, cloner: FakeGhCloner.new, hook_installer: FakeCloneHookInstaller.new,
    default_org: "d3mlabs")
    config_path = File.join(Dir.mktmpdir("clone-accessor-settings-"), "config.yml")
    File.write(config_path, default_org ? "default_org: #{default_org}\n" : "")
    Dev::Clone::Accessor.new(
      root: root, cloner: cloner, hook_installer: hook_installer,
      settings: Dev::Settings.new(config_path: config_path),
    )
  end
end
