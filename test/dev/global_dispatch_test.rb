# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev"
require "dev/global_dispatch"
require "fileutils"
require "stringio"
require "tmpdir"

# A credential accessor stand-in recording its argv, so dispatch is tested
# without hitting the real provider chain. Subclasses the real accessor to
# satisfy the dispatcher's typed constructor.
class RecordingCredAccessor < Dev::CredentialAccessor
  attr_reader :last_args

  def run(args)
    @last_args = args
  end
end unless defined?(RecordingCredAccessor)

# A clone accessor stand-in recording its argv, so dispatch is tested without
# gh or shell RC writes. Subclasses the real accessor to satisfy the
# dispatcher's typed constructor.
class RecordingCloneAccessor < Dev::Clone::Accessor
  attr_reader :last_args

  def initialize
    super(root: Dir.tmpdir)
  end

  def run(args, out: $stdout, err: $stderr)
    @last_args = args
  end
end unless defined?(RecordingCloneAccessor)

transform!(RSpock::AST::Transformation)
class Dev::GlobalDispatchTest < Minitest::Test
  test "#{name} is a global command: #{expected}" do
    Given "a dispatcher"
    dispatch = Dev::GlobalDispatch.new(cred_accessor: RecordingCredAccessor.new)

    Expect "the command is classified"
    dispatch.global_command?([name]) == expected

    Where
    name          | expected
    "cd"          | true
    "clone"       | true
    "plan"        | true
    "cred"        | true
    "learnings"   | true
    "up"          | false
    "test"        | false
    "update-deps" | false
  end

  test "dev clone dispatches globally without a dev.yml lookup" do
    Given "a recording clone accessor and a cwd with no dev.yml"
    clone = RecordingCloneAccessor.new
    dispatch = Dev::GlobalDispatch.new(clone_accessor: clone, cred_accessor: RecordingCredAccessor.new)
    cwd = Dir.mktmpdir("dispatch-cwd-")

    When "we dispatch dev clone"
    Dir.chdir(cwd) { dispatch.run(["clone", "--path", "d3mlabs/dev"]) }

    Then "the accessor received the subcommand argv"
    clone.last_args == ["--path", "d3mlabs/dev"]

    Cleanup
    FileUtils.rm_rf(cwd)
  end

  test "dev clone against an existing checkout prints a clean error and exits non-zero" do
    Given "the canonical destination already on disk"
    root = Dir.mktmpdir("dispatch-clone-")
    FileUtils.mkdir_p(File.join(root, "github.com", "d3mlabs", "dev"))
    clone_accessor = Dev::Clone::Accessor.new(root: root, hook_installer: quiet_hook_installer)
    dispatch = Dev::GlobalDispatch.new(clone_accessor: clone_accessor, cred_accessor: RecordingCredAccessor.new)
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "we dispatch the duplicate clone"
    dispatch.run(["clone", "dev"])

    Then "the error names the existing path and hints at dev cd"
    $stderr.string.include?("already exists")
    $stderr.string.include?("dev cd dev")

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(root)
  end

  test "dev learnings status dispatches globally without a dev.yml lookup" do
    Given "a knowledge repo via ENV and tmpdir-scoped XDG homes"
    dir = Dir.mktmpdir("dispatch-learnings-")
    saved = {
      "DEV_KNOWLEDGE_REPO" => ENV["DEV_KNOWLEDGE_REPO"],
      "XDG_DATA_HOME" => ENV["XDG_DATA_HOME"],
      "XDG_CONFIG_HOME" => ENV["XDG_CONFIG_HOME"],
    }
    ENV["DEV_KNOWLEDGE_REPO"] = File.join(dir, "knowledge")
    ENV["XDG_DATA_HOME"] = File.join(dir, "data")
    ENV["XDG_CONFIG_HOME"] = File.join(dir, "config")
    dispatch = Dev::GlobalDispatch.new(cred_accessor: RecordingCredAccessor.new)
    out = StringIO.new
    old_stdout = $stdout
    $stdout = out

    When "we dispatch dev learnings status from a cwd with no dev.yml"
    Dir.chdir(dir) { dispatch.run(["learnings", "status"]) }

    Then "the status reports the configured repo and the empty cache"
    out.string.include?(File.join(dir, "knowledge"))
    out.string.include?("not cloned yet")

    Cleanup
    $stdout = old_stdout
    saved.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    FileUtils.rm_rf(dir)
  end

  test "dev cd resolves through the dispatcher from a directory with no dev.yml" do
    Given "a src tree and a cwd far from any dev.yml"
    root = Dir.mktmpdir("dispatch-cd-")
    repo = File.join(root, "github.com", "d3mlabs", "dev")
    FileUtils.mkdir_p(File.join(repo, ".git"))
    cwd = Dir.mktmpdir("dispatch-cwd-")
    dispatch = Dev::GlobalDispatch.new(
      cd_accessor: Dev::Cd::Accessor.new(root: root, hook_installer: quiet_hook_installer),
      cred_accessor: RecordingCredAccessor.new,
    )
    out = StringIO.new
    old_stdout = $stdout
    $stdout = out

    When "we dispatch dev cd --resolve from that cwd"
    Dir.chdir(cwd) { dispatch.run(["cd", "--resolve", "dev"]) }

    Then "the repo path is printed without any dev.yml lookup"
    out.string == "#{File.expand_path(repo)}\n"

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
    FileUtils.rm_rf(cwd)
  end

  test "an ambiguous dev cd lists capped candidates and exits non-zero" do
    Given "twelve repos sharing a leaf prefix"
    root = Dir.mktmpdir("dispatch-cd-")
    12.times do |i|
      FileUtils.mkdir_p(File.join(root, "github.com", "org#{i}", "dev", ".git"))
    end
    dispatch = Dev::GlobalDispatch.new(
      cd_accessor: Dev::Cd::Accessor.new(root: root, hook_installer: quiet_hook_installer),
      cred_accessor: RecordingCredAccessor.new,
    )
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "we dispatch the ambiguous query"
    dispatch.run(["cd", "--resolve", "dev"])

    Then "ten candidates are shown, the rest summarized, with the Tab hint"
    $stderr.string.include?("ambiguous")
    $stderr.string.scan(%r{^  org\d+/dev$}).size == 10
    $stderr.string.include?("… and 2 more")
    $stderr.string.include?("press Tab")

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(root)
  end

  test "dev cd with no match prints a clear error and exits non-zero" do
    Given "an empty src tree"
    root = Dir.mktmpdir("dispatch-cd-")
    dispatch = Dev::GlobalDispatch.new(
      cd_accessor: Dev::Cd::Accessor.new(root: root, hook_installer: quiet_hook_installer),
      cred_accessor: RecordingCredAccessor.new,
    )
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "we dispatch an unmatched query"
    dispatch.run(["cd", "--resolve", "nonexistent"])

    Then "the error names the query"
    $stderr.string.include?("no repo matching 'nonexistent'")

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(root)
  end

  test "dev cred dispatches globally without a dev.yml lookup" do
    Given "a recording cred accessor and a cwd with no dev.yml"
    creds = RecordingCredAccessor.new
    dispatch = Dev::GlobalDispatch.new(cred_accessor: creds)
    cwd = Dir.mktmpdir("dispatch-cwd-")

    When "we dispatch dev cred"
    Dir.chdir(cwd) { dispatch.run(["cred", "get", "ns", "key"]) }

    Then "the accessor received the subcommand argv"
    creds.last_args == ["get", "ns", "key"]

    Cleanup
    FileUtils.rm_rf(cwd)
  end

  test "dev plan usage errors surface cleanly from a directory with no dev.yml" do
    Given "a cwd with no dev.yml anywhere above it"
    dispatch = Dev::GlobalDispatch.new(cred_accessor: RecordingCredAccessor.new)
    cwd = Dir.mktmpdir("dispatch-cwd-")
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "we dispatch an unknown plan subcommand"
    Dir.chdir(cwd) { dispatch.run(["plan", "bogus"]) }

    Then "the plan usage is printed (no DevYamlNotFoundError)"
    $stderr.string.include?("usage: dev plan")

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(cwd)
  end

  test "help argvs dispatch globally when no dev.yml encloses the cwd" do
    Given "a cwd with a .git dir but no dev.yml above it (a plain checkout)"
    cwd = Dir.mktmpdir("dispatch-help-")
    FileUtils.mkdir_p(File.join(cwd, ".git"))
    dispatch = Dev::GlobalDispatch.new(cred_accessor: RecordingCredAccessor.new)

    When "classifying every help spelling from that cwd"
    classified = Dir.chdir(cwd) do
      {
        bare: dispatch.global_command?([]),
        long_flag: dispatch.global_command?(["--help"]),
        short_flag: dispatch.global_command?(["-h"]),
        word: dispatch.global_command?(["help"]),
      }
    end

    Then "all classify as global"
    classified.values.all?

    Cleanup
    FileUtils.rm_rf(cwd)
  end

  test "help argvs stay with the Runner when a dev.yml encloses the cwd" do
    Given "a cwd whose parent holds a dev.yml"
    root = Dir.mktmpdir("dispatch-help-")
    File.write(File.join(root, "dev.yml"), "name: someproject\n")
    cwd = File.join(root, "nested")
    FileUtils.mkdir_p(cwd)
    dispatch = Dev::GlobalDispatch.new(cred_accessor: RecordingCredAccessor.new)

    When "classifying every help spelling from that cwd"
    classified = Dir.chdir(cwd) do
      {
        bare: dispatch.global_command?([]),
        long_flag: dispatch.global_command?(["--help"]),
        short_flag: dispatch.global_command?(["-h"]),
        word: dispatch.global_command?(["help"]),
      }
    end

    Then "none classify as global — project help renders the project catalog"
    classified.values.none?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "bare dev outside a project prints the global usage" do
    Given "a cwd with no dev.yml anywhere above it"
    cwd = Dir.mktmpdir("dispatch-help-")
    dispatch = Dev::GlobalDispatch.new(cred_accessor: RecordingCredAccessor.new)
    out = StringIO.new
    old_stdout = $stdout
    $stdout = out

    When "we dispatch the bare argv"
    Dir.chdir(cwd) { dispatch.run([]) }

    Then "the global commands render with their canonical descriptions and the project hint"
    out.string.include?("Global commands (available anywhere):")
    out.string.include?("  cd           #{Dev::Builtins::CdCommand::DESC}")
    out.string.include?("  clone        #{Dev::Builtins::CloneCommand::DESC}")
    out.string.include?("  cred         #{Dev::Builtins::CredCommand::DESC}")
    out.string.include?("  learnings    #{Dev::Builtins::LearningsCommand::DESC}")
    out.string.include?("  plan         #{Dev::Builtins::PlanCommand::DESC}")
    out.string.include?("Run dev inside a project that defines a dev.yml to see its commands.")

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(cwd)
  end

  test "project commands still require a nearby dev.yml" do
    Given "a cwd with no dev.yml anywhere above it"
    cwd = Dir.mktmpdir("dispatch-cwd-")
    Dev.instance_variable_set(:@dev_yaml_file, nil)

    When "we look up the dev.yml the Runner path needs"
    Dir.chdir(cwd) { Dev.dev_yaml_file }

    Then
    raises Dev::DevYamlNotFoundError

    Cleanup
    Dev.instance_variable_set(:@dev_yaml_file, nil)
    FileUtils.rm_rf(cwd)
  end

  private

  # A hook installer that never touches the real shell RC. Subclasses the
  # real installer to satisfy the accessors' typed constructors.
  class QuietHookInstaller < Dev::Cd::HookInstaller
    def ensure_installed = :already_present
  end

  def quiet_hook_installer
    QuietHookInstaller.new
  end
end
