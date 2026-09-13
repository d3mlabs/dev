# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/runner_registry"
require "json"

transform!(RSpock::AST::Transformation)
class Dev::RunnerRegistryTest < Minitest::Test
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

  test "find returns the named runner's id and custom labels at an org scope" do
    Given "a gh answering with two runners, one line each"
    lines = [
      runner_json(id: 7, name: "other-box", custom: ["ue-engine"]),
      runner_json(id: 42, name: "JeanPhiippesMBP", custom: %w[ai-ask ai-build]),
    ].join("\n")
    exec = RecordingExecutor.new { [lines, "", true] }
    registry = Dev::RunnerRegistry.new(executor: exec)

    When "finding by name"
    runner = registry.find(scope: "d3mlabs", name: "JeanPhiippesMBP")

    Then "the org endpoint is paginated and the read-only labels are excluded"
    exec.captures == [["gh", "api", "--paginate", "orgs/d3mlabs/actions/runners", "--jq", ".runners[]"]]
    runner.id == 42
    runner.custom_labels == %w[ai-ask ai-build]
  end

  test "find hits the repos endpoint for a repo scope" do
    Given "a gh answering with one runner"
    exec = RecordingExecutor.new { [runner_json(id: 1, name: "box", custom: ["cellbound3d"]), "", true] }
    registry = Dev::RunnerRegistry.new(executor: exec)

    When "finding at a repo scope"
    registry.find(scope: "d3mlabs/cellbound-3d", name: "box")

    Then
    exec.captures.fetch(0).fetch(3) == "repos/d3mlabs/cellbound-3d/actions/runners"
  end

  test "find is nil when no runner of that name is enrolled at the scope" do
    Given "a gh answering with unrelated runners"
    exec = RecordingExecutor.new { [runner_json(id: 7, name: "other-box", custom: []), "", true] }
    registry = Dev::RunnerRegistry.new(executor: exec)

    Expect
    registry.find(scope: "d3mlabs", name: "JeanPhiippesMBP").nil?
  end

  test "find raises when GitHub cannot be queried" do
    Given "a gh that fails (offline, auth)"
    exec = RecordingExecutor.new { ["", "connect: network is unreachable", false] }
    registry = Dev::RunnerRegistry.new(executor: exec)

    When "finding"
    registry.find(scope: "d3mlabs", name: "box")

    Then "the failure is loud, never a silent not-found"
    error = raises Dev::RunnerRegistry::QueryError
    error.message.include?("network is unreachable")
  end

  test "amend! replaces the runner's custom labels in place" do
    Given "a recording gh"
    exec = RecordingExecutor.new { ["", "", true] }
    registry = Dev::RunnerRegistry.new(executor: exec)

    When "amending"
    registry.amend!(scope: "d3mlabs", runner_id: 42, labels: %w[ai-ask ai-edit ai-build ai-split ai-learn])

    Then "one PUT carries the full custom set"
    exec.captures == [[
      "gh", "api", "-X", "PUT", "orgs/d3mlabs/actions/runners/42/labels",
      "-f", "labels[]=ai-ask", "-f", "labels[]=ai-edit", "-f", "labels[]=ai-build",
      "-f", "labels[]=ai-split", "-f", "labels[]=ai-learn"
    ]]
  end

  test "amend! raises when the PUT fails" do
    Given "a gh refusing the amend"
    # A lambda (not a plain block): blocks auto-splat their single array
    # argument under RSpock's transformation.
    responder = ->(argv) { argv.include?("PUT") ? ["", "HTTP 403", false] : ["", "", true] }
    exec = RecordingExecutor.new(&responder)
    registry = Dev::RunnerRegistry.new(executor: exec)

    When "amending"
    registry.amend!(scope: "d3mlabs", runner_id: 42, labels: ["ai-ask"])

    Then
    error = raises Dev::RunnerRegistry::AmendError
    error.message.include?("HTTP 403")
  end

  private

  # One `--jq .runners[]` output line: GitHub's runner object with read-only
  # labels (self-hosted, OS, arch) alongside the custom ones.
  def runner_json(id:, name:, custom:)
    labels = [{ "name" => "self-hosted", "type" => "read-only" }] +
             custom.map { |l| { "name" => l, "type" => "custom" } }
    JSON.generate({ "id" => id, "name" => name, "labels" => labels })
  end
end
