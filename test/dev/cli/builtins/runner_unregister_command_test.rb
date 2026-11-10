# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/builtins/runner_unregister_command"
require "dev/runner_discovery"
require "dev/runner_teardown"
require "fileutils"
require "json"
require "stringio"
require "support/answering_ui"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Cli::Builtins::RunnerUnregisterCommandTest < Minitest::Test
  include SorbetHelper

  test "traits: a visible Environment leaf that never stamps" do
    Given "the builtin"
    command = build_harness(home: Dir.mktmpdir).command

    Expect
    command.hidden? == false
    command.category == Dev::Cli::Command::Category::Environment
    command.stamps? == false
    command.desc.include?("--yes")
  end

  test "unregister <scope> resolves, asks naming scope, runner, dir and service, and tears down on yes" do
    Given "one enrollment with a service, and an operator who says yes"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner", scope: "JPDuchesne/snappy", name: "JPSFF")
    File.write(File.join(dir, ".service"), "unit\n")
    harness = build_harness(home: home, answer: true)

    When "unregistering by scope"
    harness.command.call(args: parsed_args(harness.command, ["JPDuchesne/snappy"]), context: harness.context)

    Then "the one question, defaulting to no, then the one enrollment torn down"
    harness.ui.questions == [AnsweringUi::Question.new(text: "Unregister JPSFF from JPDuchesne/snappy (~/actions-runner, service installed)?", default: false)]
    harness.torn_down.map(&:dir) == [dir]
  end

  test "a declined confirmation changes nothing and says so" do
    Given "an enrollment and an operator who says no"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    harness = build_harness(home: home, answer: false)

    When "unregistering"
    harness.command.call(args: parsed_args(harness.command, ["JPDuchesne/snappy"]), context: harness.context)

    Then
    harness.ui.asked == ["Unregister JPSFF from JPDuchesne/snappy (~/actions-runner-snappy, no service)?"]
    harness.torn_down == []
    harness.out.string.include?("nothing changed")
  end

  test "--yes skips the question" do
    Given "an enrollment and no terminal"
    home = Dir.mktmpdir
    dir = write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    harness = build_harness(home: home, answer: nil)

    When "unregistering by ~-dir with --yes"
    harness.command.call(args: parsed_args(harness.command, ["--yes", "~/actions-runner-snappy"]), context: harness.context)

    Then
    harness.ui.asked.empty?
    harness.torn_down.map(&:dir) == [dir]
  end

  test "no argument means the checkout's scope — the owner with --org — like register" do
    Given "enrollments for the checkout's repo and its org"
    home = Dir.mktmpdir
    repo_dir = write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    org_dir = write_runner(home, "actions-runner-ai", scope: "JPDuchesne", name: "JPSFF")
    harness = build_harness(home: home, repo: "JPDuchesne/snappy")

    When "unregistering with no reference, then with --org"
    harness.command.call(args: parsed_args(harness.command, ["--yes"]), context: projectless_context)
    harness.command.call(args: parsed_args(harness.command, ["--yes", "--org"]), context: projectless_context)

    Then
    harness.torn_down.map(&:dir) == [repo_dir, org_dir]
  end

  test "a scope this host serves with several slots is unregistered whole: the slots listed, one question, every slot torn down in slot order (dev#470)" do
    Given "three slots at the org, discovered out of slot order, and an operator who says yes"
    home = Dir.mktmpdir
    three = write_runner(home, "actions-runner-ai-ask-3", scope: "d3mlabs", name: "mac1-3")
    one = write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1")
    two = write_runner(home, "actions-runner-ai-ask-2", scope: "d3mlabs", name: "mac1-2")
    File.write(File.join(two, ".service"), "unit\n")
    harness = build_harness(home: home, answer: true)

    When "unregistering by scope"
    harness.command.call(args: parsed_args(harness.command, ["d3mlabs"]), context: harness.context)

    Then
    harness.ui.asked == ["Unregister all 3?"]
    harness.torn_down.map(&:dir) == [one, two, three]
    harness.out.string.include?("3 slots on this host serve d3mlabs:")
    harness.out.string.include?("  mac1 (~/actions-runner-ai-ask, no service)")
    harness.out.string.include?("  mac1-2 (~/actions-runner-ai-ask-2, service installed)")
    harness.out.string.include?("  mac1-3 (~/actions-runner-ai-ask-3, no service)")
  end

  test "declining the slots' question tears nothing down; a dir still names exactly one slot" do
    Given "two slots"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs", name: "mac1")
    two = write_runner(home, "actions-runner-ai-ask-2", scope: "d3mlabs", name: "mac1-2")
    harness = build_harness(home: home, answer: false)

    When "declining by scope, then naming slot 2's dir with --yes"
    harness.command.call(args: parsed_args(harness.command, ["d3mlabs"]), context: harness.context)
    harness.command.call(args: parsed_args(harness.command, ["--yes", "~/actions-runner-ai-ask-2"]), context: harness.context)

    Then
    harness.ui.asked == ["Unregister all 2?"]
    harness.torn_down.map(&:dir) == [two]
    harness.out.string.include?("nothing changed")
  end

  test "the teardown's resolution errors surface as they are — the shell shows the dirs to name" do
    Given "an ambiguous scope"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner", scope: "JPDuchesne/snappy", name: "JPSFF")
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    harness = build_harness(home: home)

    When "unregistering by scope"
    harness.command.call(args: parsed_args(harness.command, ["--yes", "JPDuchesne/snappy"]), context: projectless_context)

    Then
    raises Dev::RunnerTeardown::AmbiguousEnrollmentError
    harness.torn_down == []
  end

  # --- completion ---------------------------------------------------------

  test "completions offer every local enrollment's scope, then every ~-dir — discovery's order, deduplicated, never sorted" do
    Given "three enrollments: two for one scope (so the scope appears once), dirs in glob order"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner", scope: "JPDuchesne/snappy", name: "JPSFF")
    write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs/cellbound-3d", name: "JPSFF")
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    harness = build_harness(home: home)

    When "completing the first argument"
    candidates = harness.command.completions([])

    Then "scopes first (as discovered — not alphabetical), then the dirs"
    candidates == [
      "JPDuchesne/snappy", "d3mlabs/cellbound-3d",
      "~/actions-runner", "~/actions-runner-cellbound3d", "~/actions-runner-snappy"
    ]
  end

  test "completions offer nothing once an enrollment is named, and ignore flags typed before it" do
    Given "one enrollment"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    harness = build_harness(home: home)

    Expect "flags do not count as the positional; a positional ends the offer"
    harness.command.completions(["--yes"]) == ["JPDuchesne/snappy", "~/actions-runner-snappy"]
    harness.command.completions(["JPDuchesne/snappy"]) == []
    harness.command.completions(["--yes", "~/actions-runner-snappy"]) == []
  end

  test "completions on a host with no enrollments are empty, and never touch gh" do
    Given "an empty home and a repo resolver that must not be called"
    harness = build_harness(home: Dir.mktmpdir, repo_resolver: -> { raise "gh was called" })

    Expect
    harness.command.completions([]) == []
  end

  test "the default repo resolver asks RunnerSetup.current_repo — the one gh seam — and discovery is the real one" do
    Given "a bare unregister with default wiring, gh answered at RunnerSetup's seam, discovery over an empty home"
    empty_discovery = Dev::RunnerDiscovery.new(home: Dir.mktmpdir)
    Dev::RunnerDiscovery.stubs(:new).returns(empty_discovery)
    Dev::RunnerSetup.expects(:current_repo).once.returns("JPDuchesne/snappy")
    command = Dev::Cli::Builtins::RunnerUnregisterCommand.new

    When "running with no reference"
    command.call(args: no_args, context: projectless_context)

    Then "the checkout's scope was resolved through gh and nothing on the empty host serves it"
    error = raises Dev::RunnerTeardown::NoSuchEnrollmentError
    error.message.include?("JPDuchesne/snappy")
  end

  private

  Harness = Struct.new(:command, :torn_down, :ui, :out, keyword_init: true) do
    # The projectless context the command runs in, carrying the answering Ui.
    def context
      Dev::Cli::ExecutionContext.new(ui: ui)
    end
  end

  # A teardown whose resolution is real (tempdir discovery) and whose
  # teardown! only records — the CLI steps have their own tests. The Ui
  # answers every question as `answer` says (nil: no terminal).
  def build_harness(home:, repo: "JPDuchesne/snappy", repo_resolver: nil, answer: nil)
    torn_down = []
    discovery = Dev::RunnerDiscovery.new(home: home)
    teardown = Dev::RunnerTeardown.new(discovery: discovery, executor: nil, home: home)
    teardown.define_singleton_method(:teardown!) { |enrollment, ui:| torn_down << enrollment }
    out = StringIO.new
    command = Dev::Cli::Builtins::RunnerUnregisterCommand.new(
      teardown: teardown,
      discovery: discovery,
      repo_resolver: repo_resolver || -> { repo },
      out: out,
    )
    Harness.new(command: command, torn_down: torn_down, ui: AnsweringUi.new(out: out, answer: answer), out: out)
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
    Dev::Cli::ExecutionContext.new(ui: typed_mock(Dev::Ui))
  end
end
