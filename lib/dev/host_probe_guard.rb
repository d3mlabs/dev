# typed: strict
# frozen_string_literal: true

module Dev
  # Kill-switch against reading the host's platform, for processes whose
  # answers must not depend on the machine they run on: the test suite.
  # The platform seams — `RunnerUser.for_host`, `WslRunnerHost.for_host`,
  # `LinuxDataRootProvisioner.for_host` — answer nil or a collaborator by
  # probing the host (`Platform.os`, the WSL interop socket, the env), and
  # a command built on their defaults is a different command on a Mac, on
  # Linux and on WSL. A test that reaches such a default is host-dependent:
  # green on the laptop, red on the box, or the reverse (the agent's runs
  # on the WSL host found three such tests). test_helper sets
  # DEV_FORBID_HOST_PROBES=1 for every test process; each seam's default
  # argument resolves through #probe, so the test fails fast on *every*
  # host with the seam to inject named, instead of only on the host unlike
  # CI's. Outside the harness the variable is unset and the guard is a
  # no-op; it is not a user setting. The same shape as ProvisioningGuard
  # (dev#208), for a different hazard.
  module HostProbeGuard
    extend T::Sig

    # A platform default was reached while the kill-switch is armed. An
    # Exception, not a StandardError: the CLI boundary (`Cli::Runner#run`)
    # maps StandardErrors to `exit 1`, and a test through the composition
    # root would turn the refusal into a real exit that takes the suite
    # down silently instead of one red test naming the seam.
    class ProbedError < Exception; end

    ENV_VAR = "DEV_FORBID_HOST_PROBES"

    class << self
      extend T::Sig

      # Whether the kill-switch is armed in this process.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def forbidden?
        ENV.fetch(ENV_VAR, nil) == "1"
      end

      # The seam's gate: refuses the probe while armed, else answers it.
      #
      # @param what [String] what would have been read, e.g. "Platform.os"
      # @param inject [String] the parameter a test should pass instead, e.g. "host_os:"
      # @yieldreturn [Object] the probe's answer
      # @return [Object] the block's answer
      # @raise [ProbedError] while the kill-switch is armed
      sig do
        type_parameters(:T)
          .params(what: String, inject: String, block: T.proc.returns(T.type_parameter(:T)))
          .returns(T.type_parameter(:T))
      end
      def probe(what, inject:, &block)
        if forbidden?
          raise ProbedError, <<~MSG
            refusing to read #{what}: #{ENV_VAR}=1 (the test harness arms it).
            A test reached a platform seam's default, which answers differently per host — pass #{inject} (or inject the seam where the command is built) so the test says the same thing on every machine.
            If this test exercises the default itself, lift the guard for its duration (allow_host_probes / restore_host_probe_guard).
          MSG
        end

        yield
      end
    end
  end
end
