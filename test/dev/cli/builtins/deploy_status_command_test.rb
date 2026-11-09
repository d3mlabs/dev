# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/builtins/deploy_status_command"
require "dev/lifecycle"
require "support/fake_gh"
require "support/lifecycle_fixtures"
require "stringio"

# `dev deploy status` over the ledger with a scripted forge (FakeGh): one
# block per channel, in declaration order.
transform!(RSpock::AST::Transformation)
class Dev::Cli::Builtins::DeployStatusCommandTest < Minitest::Test
  include LifecycleFixtures
  include SorbetHelper

  REPO = "d3mlabs/cellbound-3d"
  DEPLOYMENTS = "repos/#{REPO}/deployments".freeze

  def setup
    @out = StringIO.new
    @gh = FakeGh.new.resolving(REPO)
  end

  def channel(name, *patterns)
    Dev::Lifecycle::Channel.new(
      name:, desc: name, accepts: patterns.map { |pattern| Dev::Lifecycle::BuildPattern.parse(pattern, all_targets) },
      publisher: Dev::Lifecycle::PublisherSpec::Script.new(command: "./bin/#{name}"),
    )
  end

  def channels = [channel("staging", "cellbound-3d-win64"), channel("steam", "cellbound-3d-steamworks"), channel("rubygems", "rspock")]

  def command = Dev::Cli::Builtins::DeployStatusCommand.new(channels:, deployments: Dev::Lifecycle::GithubDeployments.new(gh: @gh), out: @out)

  def context = Dev::Cli::ExecutionContext.new(ui: typed_mock(Dev::Ui))

  def deployment(id, ref:, track:, builds:)
    {
      "id" => id, "ref" => ref, "environment" => "x", "created_at" => "2026-11-05T17:02:11Z",
      "payload" => { "schema" => 1, "track" => track, "builds" => builds.map { |name, build_id| { "build" => name, "build_id" => build_id } } },
    }
  end

  def forge_lists(channel, deployments, ref: nil, status: nil)
    query = "environment=#{channel}&per_page=1#{ref ? "&ref=#{ref}" : ""}"
    @gh.answers(["api", "#{DEPLOYMENTS}?#{query}"], with: deployments)
    return if deployments.empty?

    @gh.answers(["api", "#{DEPLOYMENTS}/#{deployments.first["id"]}/statuses?per_page=1"], with: status ? [status] : [])
  end

  test "bare: per channel, the latest deployment's outcome, track, ref, instant and receipt, then the builds it shipped; or that nothing was" do
    Given
    forge_lists("staging", [deployment(41, ref: "3f2a1c9d8e7b", track: "testing", builds: [
      ["cellbound-3d-win64-dev", "1.2.3+3f2a1c9d8e7b"], ["cellbound-3d-win64-release", "1.2.3+3f2a1c9d8e7b"],
    ])], status: { "state" => "success", "description" => "run: ./bin/staging" })
    forge_lists("steam", [deployment(40, ref: "0123456789ab", track: "testing", builds: [["cellbound-3d-steamworks-win64-release", "1.2.3+0123456789ab"]])],
      status: { "state" => "failure", "description" => "steamcmd exited 1" })
    forge_lists("rubygems", [])

    When
    command.call(args: no_args, context:)

    Then
    @out.string == <<~OUT
      staging   ✓ testing from 3f2a1c9d8e7b at 2026-11-05 17:02 UTC — run: ./bin/staging
                cellbound-3d-win64-dev (1.2.3+3f2a1c9d8e7b)
                cellbound-3d-win64-release (1.2.3+3f2a1c9d8e7b)
      steam     ✗ testing from 0123456789ab at 2026-11-05 17:02 UTC — failed: steamcmd exited 1
                cellbound-3d-steamworks-win64-release (1.2.3+0123456789ab)
      rubygems  – nothing deployed
    OUT
  end

  test "--release V asks each channel for the release's tag only: the checklist of which channels carry it" do
    Given
    forge_lists("staging", [], ref: "v1.2.0")
    forge_lists("steam", [deployment(7, ref: "v1.2.0", track: "live", builds: [["cellbound-3d-steamworks-win64-release", "1.2.0+3f2a1c9d8e7b"]])],
      ref: "v1.2.0", status: { "state" => "success", "description" => "build 1234567" })
    forge_lists("rubygems", [deployment(8, ref: "v1.2.0", track: "live", builds: [["rspock", "1.2.0+3f2a1c9d8e7b"]])], ref: "v1.2.0")

    When
    command.call(args: parsed_args(command, ["--release", "1.2.0"]), context:)

    Then "a deployment with no status yet reads as pending"
    @out.string == <<~OUT
      staging   – v1.2.0 not deployed
      steam     ✓ live from v1.2.0 at 2026-11-05 17:02 UTC — build 1234567
                cellbound-3d-steamworks-win64-release (1.2.0+3f2a1c9d8e7b)
      rubygems  … pending live from v1.2.0 at 2026-11-05 17:02 UTC
                rspock (1.2.0+3f2a1c9d8e7b)
    OUT
  end

  test "a positional is refused: status reads every channel" do
    When
    command.call(args: parsed_args(command, ["staging"]), context:)

    Then
    error = raises Dev::Cli::Builtins::DeployStatusCommand::UnexpectedArgumentError
    error.message.include?('got "staging"')
    @gh.calls == []
  end

  test "a version that cannot name a tag is refused before the forge is asked" do
    When
    command.call(args: parsed_args(command, ["--release", "1.2 0"]), context:)

    Then
    raises Dev::Lifecycle::ReleaseTag::InvalidVersionError
    @gh.calls == []
  end

  test "the ledger's failure bubbles as its own error" do
    Given
    @gh.refuses(["api"], with: "HTTP 401: Bad credentials")

    When
    command.call(args: no_args, context:)

    Then
    raises Dev::Lifecycle::GithubDeployments::ApiError
  end

  test "the command's traits: a Lifecycle builtin named status, taking --release" do
    Expect
    Dev::Cli::Builtins::DeployStatusCommand::NAME == "status"
    command.category == Dev::Cli::Command::Category::Lifecycle
    command.flags.map(&:name) == ["--release"]
    command.desc.include?("status [--release V]")
  end
end
