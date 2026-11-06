# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/enrolled_runner"
require "dev/enrolled_runner_lookup"
require "dev/runner_registry"
require "dev/runner_setup"
require "json"

# The lookup over a real RunnerRegistry whose gh is a recording executor:
# what the Actions API answers is the only thing each case varies.
transform!(RSpock::AST::Transformation)
class Dev::EnrolledRunnerLookupTest < Minitest::Test
  # Answers capture calls from a responder and records each argv.
  class RecordingExecutor
    attr_reader :captures

    def initialize(&responder)
      @responder = responder
      @captures = []
    end

    def capture(*argv)
      @captures << argv
      @responder ? @responder.call(argv) : ["", "", true]
    end
  end

  # On the class, ahead of the tests: Where cells are evaluated there, at
  # definition.
  class << self
    # One `--jq .runners[]` output line: GitHub's runner object with
    # read-only labels (self-hosted, OS, arch) alongside the custom ones,
    # its status ("online" / "offline") and whether it is running a job.
    def runner_json(id:, name:, custom:, status: "online", busy: false)
      labels = [{ "name" => "self-hosted", "type" => "read-only" }] +
               custom.map { |l| { "name" => l, "type" => "custom" } }
      JSON.generate({ "id" => id, "name" => name, "status" => status, "busy" => busy, "labels" => labels })
    end
  end

  test "the checkout's enrolled runner is available when GitHub lists an online runner carrying the repo's label at the repo's scope" do
    Given "a box enrolled bare for the checkout, online"
    exec = RecordingExecutor.new { [runner_json(id: 7, name: "box", custom: ["cellbound-3d"]), "", true] }
    lookup = build_lookup(exec, repo: "d3mlabs/cellbound-3d")

    When
    available = lookup.available

    Then "the answer is the enrolled runner — scope and label — and the one question went to the repo's runners"
    available == Dev::EnrolledRunner.for("d3mlabs/cellbound-3d")
    exec.captures == [["gh", "api", "--paginate", "repos/d3mlabs/cellbound-3d/actions/runners", "--jq", ".runners[]"]]
  end

  test "the repo's spelling never matters: the label GitHub stores is matched case-insensitively, as GitHub routes it" do
    Given "a checkout gh spells in mixed case, and a label enrolled by hand in another case"
    exec = RecordingExecutor.new { [runner_json(id: 7, name: "box", custom: ["Cellbound-3D"]), "", true] }
    lookup = build_lookup(exec, repo: "D3MLabs/Cellbound-3D")

    Expect
    lookup.available == Dev::EnrolledRunner.new(scope: "D3MLabs/Cellbound-3D", label: "cellbound-3d")
  end

  test "nil when #{what}: the repo has no runner the remote dispatch can target" do
    Given
    exec = RecordingExecutor.new { [lines, "", true] }
    lookup = build_lookup(exec, repo: "d3mlabs/cellbound-3d")

    Expect
    lookup.available.nil?

    Where
    what                                                  | lines
    "no runner is enrolled at the scope"                  | ""
    "the enrolled runner is offline"                      | runner_json(id: 7, name: "box", custom: ["cellbound-3d"], status: "offline")
    "the scope's runners carry other labels"              | runner_json(id: 7, name: "box", custom: ["ue-engine"])
    "the only one carrying the label is offline"          | [runner_json(id: 7, name: "box", custom: ["cellbound-3d"], status: "offline"), runner_json(id: 8, name: "mac", custom: ["ue-editor"])].join("\n")
  end

  test "a busy runner is available: GitHub queues the job behind it" do
    Given
    exec = RecordingExecutor.new { [runner_json(id: 7, name: "box", custom: ["cellbound-3d"], busy: true), "", true] }
    lookup = build_lookup(exec, repo: "d3mlabs/cellbound-3d")

    Expect
    !lookup.available.nil?
  end

  test "GitHub unreachable is loud, never read as 'no runner'" do
    Given "a gh that fails (offline, unauthenticated)"
    exec = RecordingExecutor.new { ["", "connect: network is unreachable", false] }
    lookup = build_lookup(exec, repo: "d3mlabs/cellbound-3d")

    When
    lookup.available

    Then
    error = raises Dev::RunnerRegistry::QueryError
    error.message.include?("network is unreachable")
  end

  test "a checkout gh cannot resolve is the resolver's error, raised before any runner is listed" do
    Given
    exec = RecordingExecutor.new { ["", "", true] }
    lookup = Dev::EnrolledRunnerLookup.new(
      registry: Dev::RunnerRegistry.new(executor: exec),
      repo_resolver: -> { raise Dev::RunnerSetup::Error, "could not resolve the repo via gh: not a git repository" },
    )

    When
    lookup.available

    Then
    error = raises Dev::RunnerSetup::Error
    error.message.include?("not a git repository")
    exec.captures == []
  end

  test "the default repo resolver is RunnerSetup.current_repo — the one gh seam register derives its label from" do
    Given "gh answered at that seam; the registry over a recording executor"
    Dev::RunnerSetup.expects(:current_repo).once.returns("JPDuchesne/snappy")
    exec = RecordingExecutor.new { [runner_json(id: 9, name: "JPSFF", custom: ["snappy"]), "", true] }
    lookup = Dev::EnrolledRunnerLookup.new(registry: Dev::RunnerRegistry.new(executor: exec))

    Expect
    lookup.available == Dev::EnrolledRunner.for("JPDuchesne/snappy")
  end

  private

  def build_lookup(exec, repo:)
    Dev::EnrolledRunnerLookup.new(registry: Dev::RunnerRegistry.new(executor: exec), repo_resolver: -> { repo })
  end

  def runner_json(id:, name:, custom:, status: "online", busy: false)
    self.class.runner_json(id: id, name: name, custom: custom, status: status, busy: busy)
  end
end
