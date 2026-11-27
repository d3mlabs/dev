# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/dependency_service"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Cli::DependencyServiceTest < Minitest::Test
  include SorbetHelper

  test "messages serves the staleness view" do
    Given "a staleness with one drifted layer"
    staleness = typed_mock(Dev::Deps::Staleness)
    service = Dev::Cli::DependencyService.new(staleness: staleness)

    When "reading the messages"
    messages = service.messages

    Then "the messages pass through"
    _ * staleness.messages >> ["lockfiles are stale"]
    messages == ["lockfiles are stale"]
  end

  test "the no-project service has nothing to guard, report, or stamp" do
    Given "the null service for runs outside any project"
    service = Dev::Cli::NoProjectDependencyService.new
    old_stderr = $stderr
    $stderr = StringIO.new

    When "running both lifecycle calls"
    service.guard!
    service.lock!

    Then "no messages, no warnings, no raise"
    service.messages == []
    $stderr.string.empty?

    Cleanup
    $stderr = old_stderr
  end

  test "guard! is silent when everything is in sync" do
    Given "an in-sync staleness"
    staleness = typed_mock(Dev::Deps::Staleness)
    service = Dev::Cli::DependencyService.new(staleness: staleness)
    old_stderr = $stderr
    $stderr = StringIO.new

    When "guarding"
    service.guard!

    Then "nothing is reported"
    _ * staleness.messages >> []
    $stderr.string.empty?

    Cleanup
    $stderr = old_stderr
  end

  test "guard! warns on a workstation and lets the command run" do
    Given "a stale state outside CI"
    staleness = typed_mock(Dev::Deps::Staleness)
    service = Dev::Cli::DependencyService.new(staleness: staleness, env: "dev")
    old_stderr = $stderr
    $stderr = StringIO.new

    When "guarding"
    service.guard!

    Then "each message is a warning, not an error"
    _ * staleness.messages >> ["lockfiles are stale", "install is stale"]
    $stderr.string.include?("warning: lockfiles are stale")
    $stderr.string.include?("warning: install is stale")

    Cleanup
    $stderr = old_stderr
  end

  test "guard! raises StaleDependencyStateError in CI" do
    Given "a stale state in CI, where drift is a pipeline bug"
    staleness = typed_mock(Dev::Deps::Staleness)
    service = Dev::Cli::DependencyService.new(staleness: staleness, env: "ci")

    When "guarding"
    service.guard!

    Then
    _ * staleness.messages >> ["lockfiles are stale"]
    raises Dev::Cli::DependencyService::StaleDependencyStateError
  end

  test "lock! records the installed stamp and sweeps the stamps of checkouts that are gone (dev#529)" do
    Given "a staleness expecting its stamp write and its prune"
    staleness = typed_mock(Dev::Deps::Staleness)
    service = Dev::Cli::DependencyService.new(staleness: staleness)

    When "locking"
    service.lock!

    Then "the stamp was written and the orphans swept, once each"
    1 * staleness.stamp_installed!
    1 * staleness.prune_orphans! >> []
  end
end
