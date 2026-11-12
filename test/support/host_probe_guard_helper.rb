# typed: false
# frozen_string_literal: true

require "dev/host_probe_guard"
require "dev/platform"
require "dev/wsl_runner_host"

# Per-test opt-out of the host-probe kill-switch test_helper arms for the
# whole process. Only a test that *exercises a platform default itself*
# lifts the guard, and only for its own duration:
#
#   guard = allow_host_probes          # Given
#   ...
#   restore_host_probe_guard(guard)    # Cleanup
#
# Every other test keeps the guard: a `for_host` default it did not inject
# fails fast with ProbedError on every host instead of answering for this
# one. The same shape as ProvisioningGuardHelper.
module HostProbeGuardHelper
  # Lifts the guard; returns the switch's prior value for restore.
  #
  # @return [String, nil]
  def allow_host_probes
    previous = ENV.fetch(Dev::HostProbeGuard::ENV_VAR, nil)
    ENV.delete(Dev::HostProbeGuard::ENV_VAR)
    previous
  end

  # For a test through the composition root (`Dev::Cli::Runner`), which
  # builds every builtin on its platform defaults: pins the host the
  # defaults read — `Platform.os` to `os`, the WSL interop to "not WSL" —
  # and lifts the guard, so the run answers the same on every machine.
  # Returns the switch's prior value for restore_host_probe_guard; the
  # stubs are mocha's and end with the test.
  #
  # @param os [String] "darwin" / "linux"
  # @return [String, nil]
  def pin_host_platform(os:)
    Dev::Platform.stubs(:os).returns(os)
    Dev::WslRunnerHost.stubs(:for_host).returns(nil)
    allow_host_probes
  end

  # Re-arms the guard exactly as it was before allow_host_probes.
  #
  # @param previous [String, nil] allow_host_probes's return
  # @return [void]
  def restore_host_probe_guard(previous)
    if previous.nil?
      ENV.delete(Dev::HostProbeGuard::ENV_VAR)
    else
      ENV[Dev::HostProbeGuard::ENV_VAR] = previous
    end
    nil
  end
end
