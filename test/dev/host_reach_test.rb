# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/dependency"
require "dev/host_reach"
require "dev/runner_user"

transform!(RSpock::AST::Transformation)
class Dev::HostReachTest < Minitest::Test
  # Answers `gh api <path>` from a set of reachable paths; records every
  # argv so the test can see the probes ran as the runner user.
  class ProbingExecutor
    attr_reader :calls

    def initialize(reachable:, login: "d3mlabs-buildhost")
      @reachable = reachable
      @login = login
      @calls = []
    end

    def capture(*argv, chdir: nil)
      @calls << argv
      return ["#{@login}\n", "", true] if argv.last(3) == ["user", "--jq", ".login"]

      path = argv.fetch(argv.index("api") + 1)
      return ["Organization\n", "", true] if argv.last(2) == ["--jq", ".type"] && path.start_with?("users/d3mlabs")
      return ["User\n", "", true] if argv.last(2) == ["--jq", ".type"]

      @reachable.include?(path) ? ["{}", "", true] : ["", "gh: Not Found (HTTP 404)", false]
    end
  end

  def pins
    [
      dep("UnrealEngine", :gh, "repo" => "satisfactorymodding/UnrealEngine"),
      dep("unreal-engine", :gh, "repo" => "d3mlabs/unreal-engine"),
      dep("snappy-linux", :image, "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "registry" => "ghcr.io/d3mlabs"),
      dep("zstd", :brew, "tap" => "homebrew/core"),
    ]
  end

  test "targets are what a job fetches with the host identity: every gh pin's repo and every image pin's floor package — nothing else" do
    Expect
    Dev::HostReach.targets(pins).map(&:to_s) == [
      "satisfactorymodding/UnrealEngine",
      "d3mlabs/unreal-engine",
      "package ghcr.io/d3mlabs/unreal-engine-build-base",
    ]
  end

  test "check probes each target as the runner user and returns the ones it cannot read, with the grant for each" do
    Given "a runner user that can read one repo and the floor, not the other repo"
    executor = ProbingExecutor.new(reachable: [
      "repos/satisfactorymodding/UnrealEngine",
      "orgs/d3mlabs/packages/container/unreal-engine-build-base",
    ])
    reach = Dev::HostReach.new(identity: identity, executor: executor)

    When
    unreachable = reach.check(pins)

    Then "every probe ran as the runner user; the one 404 comes back with its grant, naming the login that needs it"
    executor.calls.all?(&as_runner)
    unreachable.map { |verdict| verdict.target.to_s } == ["d3mlabs/unreal-engine"]
    unreachable.fetch(0).grant == "gh api -X PUT repos/d3mlabs/unreal-engine/collaborators/d3mlabs-buildhost -f permission=pull"
  end

  test "a package is probed at the org path, then the user path (the owner's kind is not in the lock); the grant is the package's access page" do
    Given "a floor under a user, not an org"
    pin = [dep("x-linux", :image, "from" => "ghcr.io/JPDuchesne/some-base", "registry" => "ghcr.io/JPDuchesne")]
    executor = ProbingExecutor.new(reachable: ["users/JPDuchesne/packages/container/some-base", "users/JPDuchesne"])

    When
    unreachable = Dev::HostReach.new(identity: identity, executor: executor).check(pin)

    Then
    unreachable.empty?
    executor.calls.map(&api_path).include?("orgs/JPDuchesne/packages/container/some-base")
    Dev::HostReach.targets(pin).fetch(0).grant("d3mlabs-buildhost", owner_kind: :user) ==
      "grant d3mlabs-buildhost read on https://github.com/users/JPDuchesne/packages/container/some-base/settings " \
      "(or on the repo that publishes it: a package inherits its source repo's access)"
  end

  test "check! raises with every unreachable target and its grant on one line each" do
    Given
    executor = ProbingExecutor.new(reachable: [])
    reach = Dev::HostReach.new(identity: identity, executor: executor)
    error = assert_raises(Dev::HostReach::UnreachableError) { reach.check!(pins) }

    Expect
    error.message.include?("runner (d3mlabs-buildhost) cannot read what this repo's jobs fetch:")
    error.message.include?("  satisfactorymodding/UnrealEngine — gh api -X PUT repos/satisfactorymodding/UnrealEngine/collaborators/d3mlabs-buildhost -f permission=pull")
    error.message.include?("  package ghcr.io/d3mlabs/unreal-engine-build-base — grant d3mlabs-buildhost read on https://github.com/orgs/d3mlabs/packages/container/unreal-engine-build-base/settings")
    error.message.include?("then re-run dev runner register")
  end

  test "check! is silent when everything is reachable, and with no targets probes nothing" do
    Given
    executor = ProbingExecutor.new(reachable: [])

    When
    Dev::HostReach.new(identity: identity, executor: executor).check!([dep("zstd", :brew, {})])

    Then
    executor.calls.empty?
  end

  private

  # Lambdas rather than blocks: a plain block auto-splats its single array
  # argument under RSpock's transformation.
  def as_runner = ->(argv) { argv.first(4) == %w[sudo -u runner -H] }
  def api_path = ->(argv) { argv.fetch(argv.index("api") + 1) }

  def identity
    Dev::RunnerUser.new(name: "runner", home_of: ->(_user) { "/home/runner" })
  end

  def dep(name, integration, metadata)
    Dev::Deps::Dependency.new(name: name, integration: integration, group: "build", version: "1", hash: nil, metadata: metadata)
  end
end
