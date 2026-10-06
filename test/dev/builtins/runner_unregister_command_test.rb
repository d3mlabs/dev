# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/runner_unregister_command"
require "dev/confirmer"
require "dev/runner_discovery"
require "dev/runner_teardown"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::RunnerUnregisterCommandTest < Minitest::Test
  include SorbetHelper

  test "traits: a visible Lifecycle leaf that never stamps" do
    Given "the builtin"
    command = build_harness(home: Dir.mktmpdir).command

    Expect
    command.hidden? == false
    command.category == Dev::Command::Category::Lifecycle
    command.stamps? == false
    command.desc.include?("--yes")
  end

  test "unregister <scope> resolves, asks naming scope, runner, dir and service, and tears down on yes" do
    Given "one enrollment with a service, and an operator who says yes"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner", scope: "JPDuchesne/snappy", name: "JPSFF")
    File.write(File.join(dir, ".service"), "unit\n")
    harness = build_harness(home: home)
    harness.confirmer.expects(:confirm?).once
      .with("Unregister JPSFF from JPDuchesne/snappy (~/actions-runner, service installed)?").returns(true)

    When "unregistering by scope"
    harness.command.call(args: ["JPDuchesne/snappy"], context: projectless_context)

    Then "the one enrollment was torn down"
    harness.torn_down.map(&:dir) == [dir]
  end

  test "a declined confirmation changes nothing and says so" do
    Given "an enrollment and an operator who says no"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    harness = build_harness(home: home)
    harness.confirmer.expects(:confirm?).once
      .with("Unregister JPSFF from JPDuchesne/snappy (~/actions-runner-snappy, no service)?").returns(false)

    When "unregistering"
    harness.command.call(args: ["JPDuchesne/snappy"], context: projectless_context)

    Then
    harness.torn_down == []
    harness.out.string.include?("nothing changed")
  end

  test "--yes skips the question" do
    Given "an enrollment and no terminal"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    harness = build_harness(home: home)
    harness.confirmer.expects(:confirm?).never

    When "unregistering by ~-dir with --yes"
    harness.command.call(args: ["--yes", "~/actions-runner-snappy"], context: projectless_context)

    Then
    harness.torn_down.map(&:dir) == [dir]
  end

  test "no argument means the checkout's scope — the owner with --org — like register" do
    Given "enrollments for the checkout's repo and its org"
    home = Dir.mktmpdir
    repo_dir = write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    org_dir = write_runner(home, "actions-runner-ai", scope: "JPDuchesne", name: "JPSFF")
    harness = build_harness(home: home, repo: "JPDuchesne/snappy")

    When "unregistering with no reference, then with --org"
    harness.command.call(args: ["--yes"], context: projectless_context)
    harness.command.call(args: ["--yes", "--org"], context: projectless_context)

    Then
    harness.torn_down.map(&:dir) == [repo_dir, org_dir]
  end

  test "the teardown's resolution errors surface as they are — the shell shows the dirs to name" do
    Given "an ambiguous scope"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner", scope: "JPDuchesne/snappy", name: "JPSFF")
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    harness = build_harness(home: home)

    When "unregistering by scope"
    harness.command.call(args: ["--yes", "JPDuchesne/snappy"], context: projectless_context)

    Then
    raises Dev::RunnerTeardown::AmbiguousEnrollmentError
    harness.torn_down == []
  end

  test "the default wiring builds the real teardown and asks at the terminal" do
    Given "a command with default collaborators"
    command = Dev::Builtins::RunnerUnregisterCommand.new

    Expect "construction alone touches nothing"
    command.is_a?(Dev::BuiltinCommand)
  end

  private

  Harness = Struct.new(:command, :torn_down, :confirmer, :out, keyword_init: true)

  # A teardown whose resolution is real (tempdir discovery) and whose
  # teardown! only records — the CLI steps have their own tests.
  def build_harness(home:, repo: "JPDuchesne/snappy")
    torn_down = []
    discovery = Dev::RunnerDiscovery.new(home: home)
    teardown = Dev::RunnerTeardown.new(discovery: discovery, executor: nil, out: StringIO.new, home: home)
    teardown.define_singleton_method(:teardown!) { |enrollment| torn_down << enrollment }
    confirmer = typed_mock(Dev::Confirmer)
    out = StringIO.new
    command = Dev::Builtins::RunnerUnregisterCommand.new(
      teardown: teardown,
      discovery: discovery,
      repo_resolver: -> { repo },
      confirmer: confirmer,
      out: out,
    )
    Harness.new(command: command, torn_down: torn_down, confirmer: confirmer, out: out)
  end

  # A .runner record the way config.sh writes it (UTF-8 BOM + JSON).
  def write_runner(home, dir_name, scope:, name:)
    dir = File.join(home, dir_name)
    FileUtils.mkdir_p(dir)
    record = { "agentName" => name, "gitHubUrl" => "https://github.com/#{scope}" }
    File.write(File.join(dir, ".runner"), "\uFEFF#{JSON.generate(record)}")
    dir
  end

  def projectless_context
    Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui))
  end
end
