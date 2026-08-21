# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/dependency_service"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::DependencyServiceTest < Minitest::Test
  include SorbetHelper

  test "messages serves the staleness view" do
    Given "a staleness with one drifted layer"
    service = build_service(messages: ["lockfiles are stale"])

    Expect "the messages pass through"
    service.messages == ["lockfiles are stale"]
  end

  test "guard! is silent when everything is in sync" do
    Given "an in-sync staleness"
    service = build_service(messages: [])
    old_stderr = $stderr
    $stderr = StringIO.new

    When "guarding"
    service.guard!

    Then "nothing is reported"
    $stderr.string.empty?

    Cleanup
    $stderr = old_stderr
  end

  test "guard! warns on a workstation and lets the command run" do
    Given "a stale state outside CI"
    service = build_service(messages: ["lockfiles are stale", "install is stale"])
    Dev::Deps.stubs(:detect_env).returns("dev")
    old_stderr = $stderr
    $stderr = StringIO.new

    When "guarding"
    service.guard!

    Then "each message is a warning, not an error"
    $stderr.string.include?("warning: lockfiles are stale")
    $stderr.string.include?("warning: install is stale")

    Cleanup
    $stderr = old_stderr
  end

  test "guard! raises StaleDependencyStateError in CI" do
    Given "a stale state in CI, where drift is a pipeline bug"
    service = build_service(messages: ["lockfiles are stale"])
    Dev::Deps.stubs(:detect_env).returns("ci")

    When "guarding"
    service.guard!

    Then
    raises Dev::DependencyService::StaleDependencyStateError
  end

  test "guard! surfaces a stale host baseline as a warning, never a block — even in CI" do
    Given "a stale baseline with an otherwise in-sync project, in CI"
    service = build_service(messages: [], baseline_message: "host baseline stale — run `dev up`")
    Dev::Deps.stubs(:detect_env).returns("ci")
    old_stderr = $stderr
    $stderr = StringIO.new

    When "guarding"
    service.guard!

    Then "the nag is advisory and the command proceeds"
    $stderr.string.include?("warning: host baseline stale — run `dev up`")

    Cleanup
    $stderr = old_stderr
  end

  test "guard! stays quiet about a fresh baseline" do
    Given "an in-sync project and baseline"
    service = build_service(messages: [], baseline_message: nil)
    old_stderr = $stderr
    $stderr = StringIO.new

    When "guarding"
    service.guard!

    Then
    $stderr.string.empty?

    Cleanup
    $stderr = old_stderr
  end

  test "lock! records the installed stamp" do
    Given "a staleness expecting its stamp write"
    staleness = typed_mock(Dev::Deps::Staleness)
    staleness.expects(:stamp_installed!).once
    service = Dev::DependencyService.new(staleness: staleness, baseline: quiet_baseline)

    When "locking"
    service.lock!

    Then "the expectation on the staleness holds"
    true
  end

  private

  def build_service(messages:, baseline_message: nil)
    staleness = typed_mock(Dev::Deps::Staleness)
    staleness.stubs(:messages).returns(messages)
    baseline = typed_mock(Dev::Deps::Baseline)
    baseline.stubs(:message).returns(baseline_message)
    Dev::DependencyService.new(staleness: staleness, baseline: baseline)
  end

  def quiet_baseline
    baseline = typed_mock(Dev::Deps::Baseline)
    baseline.stubs(:message).returns(nil)
    baseline
  end
end
