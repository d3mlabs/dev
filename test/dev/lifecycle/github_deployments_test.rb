# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "support/fake_gh"
require "time"

# The ledger against a scripted gh (FakeGh): what dev asks the forge and
# how it reads the answers. gh is the one true boundary here.
transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::GithubDeploymentsTest < Minitest::Test
  RECORD = Dev::Lifecycle::DeploymentRecord
  STATE = Dev::Lifecycle::DeploymentState
  TRACK = Dev::Lifecycle::Track

  def record(channel: "staging", state: STATE::Success, description: "run: ./bin/stage", track: TRACK::Testing, ref: "3f2a1c9d8e7b")
    RECORD.new(
      channel:, ref:, track:, state:, description:,
      builds: [RECORD::DeployedBuild.new(name: "cellbound-3d-win64-dev", build_id: Dev::Lifecycle::BuildId.new("1.2.0+3f2a1c9d8e7b"))],
    )
  end

  def deployment_json(id: 41, ref: "3f2a1c9d8e7b", payload: record.payload)
    { "id" => id, "ref" => ref, "environment" => "staging", "payload" => payload, "created_at" => "2026-11-05T17:02:11Z" }
  end

  test "recording a deploy creates the deployment with dev's payload and GitHub's two defaults off, then its one status carrying the receipt" do
    Given
    gh = FakeGh.new.resolving("d3mlabs/cellbound-3d")
      .answers(["api", "-X", "POST", "--input", "-", "repos/d3mlabs/cellbound-3d/deployments"], with: deployment_json)
      .answers(["api", "-X", "POST", "--input", "-", "repos/d3mlabs/cellbound-3d/deployments/41/statuses"], with: { "state" => "success" })
    ledger = Dev::Lifecycle::GithubDeployments.new(gh:)

    When
    deployment = ledger.record(record)

    Then
    deployment == Dev::Lifecycle::Deployment.new(
      record:, id: 41, created_at: Time.utc(2026, 11, 5, 17, 2, 11), url: "https://github.com/d3mlabs/cellbound-3d/deployments/staging",
    )
    gh.posted == [
      {
        "ref" => "3f2a1c9d8e7b",
        "environment" => "staging",
        "description" => "dev deploy staging: cellbound-3d-win64-dev",
        "payload" => { "schema" => 1, "track" => "testing", "builds" => [{ "build" => "cellbound-3d-win64-dev", "build_id" => "1.2.0+3f2a1c9d8e7b" }] },
        "auto_merge" => false,
        "required_contexts" => [],
        "production_environment" => false,
      },
      { "state" => "success", "description" => "run: ./bin/stage" },
    ]
  end

  test "a live-track record marks the environment production, and a failure's description is cut to GitHub's 140 characters" do
    Given
    gh = FakeGh.new.resolving("d3mlabs/cellbound-3d")
      .answers(["api", "-X", "POST", "--input", "-", "repos/d3mlabs/cellbound-3d/deployments"], with: deployment_json(ref: "v1.2.0"))
      .answers(["api", "-X", "POST", "--input", "-", "repos/d3mlabs/cellbound-3d/deployments/41/statuses"], with: { "state" => "failure" })

    When
    Dev::Lifecycle::GithubDeployments.new(gh:).record(record(track: TRACK::Live, ref: "v1.2.0", state: STATE::Failure, description: "x" * 200))

    Then
    gh.posted.first["production_environment"] == true
    gh.posted.last == { "state" => "failure", "description" => "x" * 140 }
  end

  test "the repo is read from the checkout once, on first use, and reused" do
    Given
    gh = FakeGh.new.resolving("d3mlabs/cellbound-3d")
      .answers(["api", "repos/d3mlabs/cellbound-3d/deployments?environment=staging&per_page=1"], with: [])
      .answers(["api", "repos/d3mlabs/cellbound-3d/deployments?environment=steam&per_page=1"], with: [])
    ledger = Dev::Lifecycle::GithubDeployments.new(gh:)

    When
    first = ledger.latest(channel: "staging")
    second = ledger.latest(channel: "steam")

    Then
    first.nil? && second.nil?
    gh.calls.count { |call| call.argv.first == "repo" } == 1
  end

  test "the latest deployment of a channel reads back with its latest status; one of a ref when asked" do
    Given
    gh = FakeGh.new.resolving("d3mlabs/cellbound-3d")
      .answers(["api", "repos/d3mlabs/cellbound-3d/deployments?environment=steam&per_page=1&ref=v1.2.0"], with: [deployment_json(id: 7, ref: "v1.2.0")])
      .answers(["api", "repos/d3mlabs/cellbound-3d/deployments/7/statuses?per_page=1"], with: [{ "state" => "success", "description" => "build 1234567" }])

    When
    deployment = Dev::Lifecycle::GithubDeployments.new(gh:).latest(channel: "steam", ref: "v1.2.0")

    Then
    deployment.id == 7
    deployment.created_at == Time.utc(2026, 11, 5, 17, 2, 11)
    deployment.url == "https://github.com/d3mlabs/cellbound-3d/deployments/steam"
    deployment.record == record(channel: "steam", ref: "v1.2.0", description: "build 1234567")
  end

  test "a deployment with no status yet is pending, as GitHub's UI reads it" do
    Given
    gh = FakeGh.new.resolving("d3mlabs/cellbound-3d")
      .answers(["api", "repos/d3mlabs/cellbound-3d/deployments?environment=staging&per_page=1"], with: [deployment_json])
      .answers(["api", "repos/d3mlabs/cellbound-3d/deployments/41/statuses?per_page=1"], with: [])

    When
    deployment = Dev::Lifecycle::GithubDeployments.new(gh:).latest(channel: "staging")

    Then
    deployment.record.state == STATE::Pending
    deployment.record.description.nil?
  end

  test "a channel name is query-encoded" do
    Given
    gh = FakeGh.new.resolving("o/r").answers(["api", "repos/o/r/deployments?environment=steam+beta&per_page=1"], with: [])

    Expect
    Dev::Lifecycle::GithubDeployments.new(gh:).latest(channel: "steam beta").nil?
  end

  class << self
    # A gh that resolves the repo and then answers the API calls in order
    # (class-level: Where cells are evaluated while the class is defined).
    def forge_answering(*api_answers)
      api_answers.reduce(FakeGh.new.resolving("o/r")) { |gh, answer| gh.answers(["api"], with: answer) }
    end
  end

  test "every way the forge can fail is a typed ledger error: #{fault}" do
    Given
    ledger = Dev::Lifecycle::GithubDeployments.new(gh: gh)

    When
    ledger.latest(channel: "staging")

    Then
    error = raises(error_class)
    error.is_a?(Dev::Lifecycle::GithubDeployments::Error)
    error.message.include?(mention)

    Where
    fault                         | gh                                                                                                                                                                     | error_class                                                 | mention
    "no repo for the checkout"    | FakeGh.new.refuses(["repo", "view"], with: "no git remotes found")                                                                                                     | Dev::Lifecycle::GithubDeployments::RepoUnresolvedError      | "could not resolve the repo"
    "an empty repo name"          | FakeGh.new.answers(["repo", "view"], with: "\n")                                                                                                                       | Dev::Lifecycle::GithubDeployments::RepoUnresolvedError      | "gh named no repo"
    "the API refusing"            | FakeGh.new.resolving("o/r").refuses(["api"], with: "HTTP 403: Resource not accessible by integration")                                                                 | Dev::Lifecycle::GithubDeployments::ApiError                 | "could not be read: gh api"
    "not JSON"                    | forge_answering("<html>")                                                                                                                                              | Dev::Lifecycle::GithubDeployments::MalformedDeploymentError | "other than JSON"
    "an object where a list was"  | forge_answering({ "message" => "Not Found" })                                                                                                                          | Dev::Lifecycle::GithubDeployments::MalformedDeploymentError | "not a list"
    "a list of non-objects"       | forge_answering([1])                                                                                                                                                   | Dev::Lifecycle::GithubDeployments::MalformedDeploymentError | "not an object"
    "a deployment with no id"     | forge_answering([{ "ref" => "x" }])                                                                                                                                    | Dev::Lifecycle::GithubDeployments::MalformedDeploymentError | "carries no id"
    "a payload dev did not write" | forge_answering([{ "id" => 1, "ref" => "x", "payload" => "by hand", "created_at" => "2026-11-05T17:02:11Z" }], [{ "state" => "success" }])                             | Dev::Lifecycle::GithubDeployments::MalformedDeploymentError | "not an object"
    "a state off GitHub's set"    | forge_answering([{ "id" => 1, "ref" => "x", "payload" => { "track" => "testing", "builds" => [] }, "created_at" => "2026-11-05T17:02:11Z" }], [{ "state" => "done" }]) | Dev::Lifecycle::GithubDeployments::MalformedDeploymentError | "unknown deployment state"
  end

  test "a write the forge refuses names the write" do
    Given
    gh = FakeGh.new.resolving("o/r").refuses(["api", "-X", "POST"], with: "HTTP 422: No ref found for: 3f2a1c9d8e7b")

    When
    Dev::Lifecycle::GithubDeployments.new(gh:).record(record)

    Then
    error = raises Dev::Lifecycle::GithubDeployments::ApiError
    error.message.include?("could not be written: gh api -X POST --input - repos/o/r/deployments failed")
    error.message.include?("No ref found")
  end
end
