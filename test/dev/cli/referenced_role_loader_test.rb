# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/referenced_role_loader"
require "dev/deps/dependency"
require "dev/runner_role"

transform!(RSpock::AST::Transformation)
class Dev::Cli::ReferencedRoleLoaderTest < Minitest::Test
  # A gh that answers each argv from a table and records what it was asked.
  class CannedGh
    attr_reader :calls

    def initialize(answers)
      @answers = answers
      @calls = []
    end

    def capture(*argv, chdir: nil, stdin: nil)
      @calls << argv
      @answers.fetch(argv)
    end
  end

  AGENT_LABELS = %w[ai-ask ai-edit ai-split ai-build ai-learn].freeze
  REFERENCE = Dev::RunnerRole::Reference.new(name: "agent", declaring_repo: "d3mlabs/ai-flow")
  AI_FLOW_PIN = Dev::Deps::Dependency.new(
    name: "ai-flow", integration: :gh, group: :app, version: "2.4.1", hash: nil, metadata: { "repo" => "d3mlabs/ai-flow" },
  )
  OTHER_PIN = Dev::Deps::Dependency.new(
    name: "ue", integration: :gh, group: :build, version: "5.8", hash: nil, metadata: { "repo" => "d3mlabs/unreal-engine" },
  )
  READ_AT_PIN = [
    "gh", "api", "-X", "GET", "-H", "Accept: application/vnd.github.raw", "-f", "ref=2.4.1", "repos/d3mlabs/ai-flow/contents/dev.yml",
  ].freeze
  AI_FLOW_DEV_YML = <<~YAML
    name: ai-flow
    runner_roles:
      agent:
        labels: [ai-ask, ai-edit, ai-split, ai-build, ai-learn]
        group: ai-flow
        workflows: [.github/workflows/ai-commands.yml, .github/workflows/origin-firing.yml]
        job_identity: ai-agent
      orchestrator:
        labels: [ai-orchestrator]
        group: { name: ai-orchestrator, visibility: all }
        workflows: [.github/workflows/ai-commands.yml]
    commands:
      build:
        run: ./bin/build.sh
  YAML

  test "the role is the declaring repo's declaration at the version the lock pins, bound at repo scope" do
    Given "ai-flow's dev.yml at the pinned tag"
    gh = CannedGh.new(READ_AT_PIN => [AI_FLOW_DEV_YML, "", true])

    When
    role = build_loader(gh).load(REFERENCE, [OTHER_PIN, AI_FLOW_PIN])

    Then "the labels and job identity as declared there; no group — this repo's lane"
    role.referenced?
    role.name == "agent"
    role.labels == AGENT_LABELS
    role.job_identity == "ai-agent"
    role.group.nil?
    !role.org_scoped?
    # One read, at the pin's version.
    gh.calls == [READ_AT_PIN]
  end

  test "a lock pinning nothing from the declaring repo is refused before gh is asked" do
    Given
    gh = CannedGh.new({})

    When
    build_loader(gh).load(REFERENCE, [OTHER_PIN])

    Then
    error = raises Dev::RunnerRole::Reference::NotDependedOnError
    error.message.include?("this checkout's lock pins nothing from it")
    gh.calls.empty?
  end

  test "a declaring repo without a dev.yml at the pinned version (or not visible) is refused naming the repo, the file and the version" do
    Given
    gh = CannedGh.new(READ_AT_PIN => ["", "gh: Not Found (HTTP 404)", false])

    When
    build_loader(gh).load(REFERENCE, [AI_FLOW_PIN])

    Then
    error = raises Dev::Cli::ReferencedRoleLoader::QueryError
    error.message.include?("d3mlabs/ai-flow has no dev.yml at 2.4.1, or the repo is not visible to this gh login")
  end

  test "any other gh failure is refused with gh's reason" do
    Given
    gh = CannedGh.new(READ_AT_PIN => ["", "gh: You are not logged into any GitHub hosts\n", false])

    When
    build_loader(gh).load(REFERENCE, [AI_FLOW_PIN])

    Then
    error = raises Dev::Cli::ReferencedRoleLoader::QueryError
    error.message == "could not read d3mlabs/ai-flow's dev.yml at 2.4.1: gh: You are not logged into any GitHub hosts"
  end

  test "a declaring project whose dev.yml at that version has #{description} is refused as not declaring the role" do
    Given
    gh = CannedGh.new(READ_AT_PIN => [dev_yml, "", true])

    When
    build_loader(gh).load(REFERENCE, [AI_FLOW_PIN])

    Then
    error = raises Dev::Cli::ReferencedRoleLoader::NotDeclaredError
    error.message.include?("runner role 'agent' is referenced from d3mlabs/ai-flow")
    error.message.include?(fragment)

    Where
    description                      | dev_yml                                                  | fragment
    "no runner_roles block"          | "name: ai-flow\ncommands: {}\n"                          | "at 2.4.1 (the version this checkout's lock pins) declares no such role"
    "other roles only"               | "runner_roles:\n  farm:\n    labels: [ue]\n"             | "declares no such role"
    "a document that is not a map"   | "- agent\n"                                              | "declares no such role"
    "a reference to a third project" | "runner_roles:\n  agent:\n    from: d3mlabs/upstream\n"  | "references it in turn (from d3mlabs/upstream) — a reference names the project that declares the role; reference d3mlabs/upstream"
  end

  test "a malformed runner_roles block in the declaring project's dev.yml surfaces as the grammar's refusal" do
    Given
    gh = CannedGh.new(READ_AT_PIN => ["runner_roles:\n  agent:\n    labels: ai-ask\n", "", true])

    When
    build_loader(gh).load(REFERENCE, [AI_FLOW_PIN])

    Then
    error = raises Dev::Cli::RunnerRoleParser::RunnerRoleError
    error.message.include?("`agent` needs a `labels:` list")
  end

  private

  def build_loader(gh)
    Dev::Cli::ReferencedRoleLoader.new(executor: gh, parser: Dev::Cli::RunnerRoleParser.new)
  end
end
