# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/provisioning_guard"

transform!(RSpock::AST::Transformation)
class ProvisioningGuardTest < Minitest::Test
  test "the test harness arms the guard for every test process" do
    Expect "test_helper set the kill-switch, so a missed stub fails fast instead of installing"
    ENV[Dev::ProvisioningGuard::ENV_VAR] == "1"
    Dev::ProvisioningGuard.forbidden? == true
  end

  test "check! raises ForbiddenError naming the action, the switch and the stub to use" do
    Given "the guard armed (as under the harness)"
    previous = allow_provisioning
    ENV[Dev::ProvisioningGuard::ENV_VAR] = "1"

    When "a real-work seam asks"
    error = assert_raises(Dev::ProvisioningGuard::ForbiddenError) do
      Dev::ProvisioningGuard.check!("rbenv install 4.0.1", stub_hint: "Dev::ShadowenvRuby.stubs(:converge!)")
    end

    Then "the message says what was refused, why, and how to fix the test"
    error.message.include?("refusing to rbenv install 4.0.1")
    error.message.include?(Dev::ProvisioningGuard::ENV_VAR)
    error.message.include?("Dev::ShadowenvRuby.stubs(:converge!)")

    Cleanup
    restore_provisioning_guard(previous)
  end

  test "check! is a no-op when the switch is #{label}" do
    Given "the switch #{label}"
    previous = allow_provisioning
    ENV[Dev::ProvisioningGuard::ENV_VAR] = value unless value.nil?

    When "a real-work seam asks"
    Dev::ProvisioningGuard.check!("brew install libyaml", stub_hint: "n/a")

    Then "real provisioning (a user's `dev up`) is never blocked"
    Dev::ProvisioningGuard.forbidden? == false

    Cleanup
    restore_provisioning_guard(previous)

    Where
    label      | value
    "unset"    | nil
    "not \"1\"" | "0"
  end
end
