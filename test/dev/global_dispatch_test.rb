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
    "plan"        | true
    "cred"        | true
    "up"          | false
    "test"        | false
    "update-deps" | false
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

  # A hook installer that never touches the real shell RC.
  def quiet_hook_installer
    installer = Object.new
    def installer.ensure_installed = :already_present
    installer
  end
end
