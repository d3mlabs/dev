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

  test "no argument lists this host's enrollments by scope and asks which scope or dir — the picked one is then unregistered as if named (dev#623)" do
    Given "the Mac: three org agent slots in dirs named from history, and cellbound-3d's own; the operator picks the org scope, then says yes"
    home = Dir.mktmpdir
    org_one = write_runner(home, "actions-runner-cellbound3d", scope: "d3mlabs", name: "mac-agent")
    org_two = write_runner(home, "actions-runner-cellbound3d-2", scope: "d3mlabs", name: "mac-agent-2")
    File.write(File.join(org_two, ".service"), "unit\n")
    write_runner(home, "actions-runner-ai-ask", scope: "d3mlabs/cellbound-3d", name: "mac-agent")
    harness = build_harness(home: home, answer: true, pick: "d3mlabs")

    When "unregistering with no reference"
    harness.command.call(args: parsed_args(harness.command, []), context: harness.context)

    Then "the listing is grouped by scope in discovery order, the choice offers every scope then every dir — what Tab completes — and the pick resolves like the argument would"
    harness.out.string.start_with?(<<~TEXT)
      This host's enrollments:
        d3mlabs/cellbound-3d — 1 slot
          mac-agent (~/actions-runner-ai-ask, no service)
        d3mlabs — 2 slots
          mac-agent (~/actions-runner-cellbound3d, no service)
          mac-agent-2 (~/actions-runner-cellbound3d-2, service installed)
    TEXT
    harness.ui.choices == [AnsweringUi::Choice.new(
      text: "Unregister which scope or dir?",
      options: ["d3mlabs/cellbound-3d", "d3mlabs", "~/actions-runner-ai-ask", "~/actions-runner-cellbound3d", "~/actions-runner-cellbound3d-2"],
    )]
    harness.ui.asked == ["Unregister all 2?"]
    harness.torn_down.map(&:dir) == [org_one, org_two]
  end

  test "no argument and no terminal to ask at: nothing changed, the refusal names the scopes to pick from" do
    Given "two scopes and no terminal"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    write_runner(home, "actions-runner-ai", scope: "JPDuchesne", name: "JPSFF-agent")
    harness = build_harness(home: home, pick: nil)

    When
    harness.command.call(args: parsed_args(harness.command, []), context: harness.context)

    Then
    error = raises Dev::Cli::Builtins::RunnerUnregisterCommand::UnnamedEnrollmentError
    error.message == "nothing changed: no terminal to ask at — name the enrollment: `dev runner unregister <scope>` or `<dir>` " \
                     "(this host serves JPDuchesne: 1 slot, JPDuchesne/snappy: 1 slot)"
    harness.torn_down == []
  end

  test "--yes with no argument refuses as ambiguous before listing or asking anything — a bare yes names nothing to be sure of" do
    Given "two scopes and an operator who would say yes to anything"
    home = Dir.mktmpdir
    write_runner(home, "actions-runner-snappy", scope: "JPDuchesne/snappy", name: "JPSFF")
    write_runner(home, "actions-runner-ai", scope: "JPDuchesne", name: "JPSFF-agent")
    harness = build_harness(home: home, answer: true, pick: "JPDuchesne")

    When
    harness.command.call(args: parsed_args(harness.command, ["--yes"]), context: harness.context)

    Then
    error = raises Dev::Cli::Builtins::RunnerUnregisterCommand::UnnamedEnrollmentError
    error.message == "nothing changed: --yes with no enrollment named — name the enrollment: `dev runner unregister <scope>` or `<dir>` " \
                     "(this host serves JPDuchesne: 1 slot, JPDuchesne/snappy: 1 slot)"
    harness.ui.choices.empty?
    harness.out.string.empty?
    harness.torn_down == []
  end

  test "no argument on a host with nothing enrolled: nothing to list, nothing to ask" do
    Given "an empty home"
    harness = build_harness(home: Dir.mktmpdir, pick: "anything")

    When
    harness.command.call(args: parsed_args(harness.command, []), context: harness.context)

    Then
    raises Dev::Cli::Builtins::RunnerUnregisterCommand::NothingEnrolledError
    harness.ui.choices.empty?
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

  test "completions on a host with no enrollments are empty" do
    Given "an empty home"
    harness = build_harness(home: Dir.mktmpdir)

    Expect
    harness.command.completions([]) == []
  end

  test "the default wiring is discovery over this user's home, and nothing else — unregister never asks gh" do
    Given "a bare unregister with default wiring, discovery over an empty home"
    empty_discovery = Dev::RunnerDiscovery.new(home: Dir.mktmpdir)
    Dev::RunnerDiscovery.stubs(:new).returns(empty_discovery)
    command = Dev::Cli::Builtins::RunnerUnregisterCommand.new

    When "running with no reference"
    command.call(args: no_args, context: projectless_context)

    Then "the empty host has nothing to pick from"
    raises Dev::Cli::Builtins::RunnerUnregisterCommand::NothingEnrolledError
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
  # answers every question as `answer` says and every choice as `pick`
  # says (nil: no terminal).
  def build_harness(home:, answer: nil, pick: nil)
    torn_down = []
    discovery = Dev::RunnerDiscovery.new(home: home)
    teardown = Dev::RunnerTeardown.new(discovery: discovery, executor: nil, home: home)
    teardown.define_singleton_method(:teardown!) { |enrollment, ui:| torn_down << enrollment }
    out = StringIO.new
    command = Dev::Cli::Builtins::RunnerUnregisterCommand.new(teardown: teardown, discovery: discovery, out: out)
    Harness.new(command: command, torn_down: torn_down, ui: AnsweringUi.new(out: out, answer: answer, pick: pick), out: out)
  end

  # A .runner record the way config.sh writes it (UTF-8 BOM + JSON).
  def write_runner(home, dir_name, scope:, name:)
    dir = File.join(home, dir_name)
    FileUtils.mkdir_p(dir)
    record = { "agentId" => 1, "agentName" => name, "gitHubUrl" => "https://github.com/#{scope}" }
    File.write(File.join(dir, ".runner"), "\uFEFF#{JSON.generate(record)}")
    dir
  end

  def projectless_context
    Dev::Cli::ExecutionContext.new(ui: typed_mock(Dev::Ui))
  end
end
