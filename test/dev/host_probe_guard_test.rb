# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/host_probe_guard"
require "dev/runner_user"
require "dev/wsl_runner_host"
require "dev/linux_data_root_provisioner"

transform!(RSpock::AST::Transformation)
class HostProbeGuardTest < Minitest::Test
  test "the test harness arms the guard for every test process" do
    Expect "test_helper set the kill-switch, so a host-platform default fails fast on every host instead of only on the ones unlike CI's"
    ENV[Dev::HostProbeGuard::ENV_VAR] == "1"
    Dev::HostProbeGuard.forbidden? == true
  end

  test "probe raises ProbedError naming the probe and the seam to inject, and never runs the block" do
    Given "the guard armed (as under the harness)"
    ran = false

    When "a platform seam is asked for its default"
    error = assert_raises(Dev::HostProbeGuard::ProbedError) do
      Dev::HostProbeGuard.probe("Platform.os", inject: "host_os:") { ran = true }
    end

    Then "the message says what would have been read and what the test should have passed; the host was not read"
    error.message.include?("Platform.os")
    error.message.include?("host_os:")
    error.message.include?(Dev::HostProbeGuard::ENV_VAR)
    ran == false
  end

  test "probe answers the block when the switch is #{label}: a user's command reads its host" do
    Given "the switch #{label}"
    previous = allow_host_probes
    ENV[Dev::HostProbeGuard::ENV_VAR] = value unless value.nil?

    When
    answer = Dev::HostProbeGuard.probe("Platform.os", inject: "host_os:") { "linux" }

    Then
    answer == "linux"
    Dev::HostProbeGuard.forbidden? == false

    Cleanup
    restore_host_probe_guard(previous)

    Where
    label      | value
    "unset"    | nil
    "not \"1\"" | "0"
  end

  test "#{seam}'s default is a host probe: under the harness it refuses, so a test that builds a command on its platform defaults fails the same way on a Mac, on Linux and on WSL" do
    When "a command is built on the seam's default under the harness"
    error = assert_raises(Dev::HostProbeGuard::ProbedError) { default.call }

    Then "refused, on this host and every other"
    error.message.include?(Dev::HostProbeGuard::ENV_VAR)

    Where
    seam                           | default
    "RunnerUser.for_host"          | -> { Dev::RunnerUser.for_host }
    "WslRunnerHost.for_host"       | -> { Dev::WslRunnerHost.for_host }
    "LinuxDataRootProvisioner.for_host" | -> { Dev::LinuxDataRootProvisioner.for_host }
  end
end
