# typed: strict
# frozen_string_literal: true

module Dev
  # Kill-switch against real provisioning, for processes that must never
  # install anything: the test suite (dev#208). test_helper sets
  # DEV_FORBID_PROVISIONING=1 for every test process; the install seams the
  # provisioners cannot inject — `rbenv install`, `brew install` — call
  # check! right before doing the work, so a test that reached one without
  # stubbing its boundary fails in milliseconds with a pointed message
  # instead of building a Ruby on the developer's machine. Outside the
  # harness the variable is unset and the guard is a no-op; it is not a user
  # setting.
  module ProvisioningGuard
    extend T::Sig

    # A real install seam was reached while the kill-switch is armed.
    class ForbiddenError < RuntimeError; end

    ENV_VAR = "DEV_FORBID_PROVISIONING"

    class << self
      extend T::Sig

      # Whether the kill-switch is armed in this process.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def forbidden?
        ENV.fetch(ENV_VAR, nil) == "1"
      end

      # The seam's gate: refuses the action while armed, else returns.
      #
      # @param action [String] what would have run, e.g. "rbenv install 4.0.1"
      # @param stub_hint [String] the boundary a test should have stubbed
      # @return [void]
      # @raise [ForbiddenError] while the kill-switch is armed
      sig { params(action: String, stub_hint: String).void }
      def check!(action, stub_hint:)
        return unless forbidden?

        raise ForbiddenError, <<~MSG
          refusing to #{action}: #{ENV_VAR}=1 (the test harness arms it).
          A test reached a real provisioning seam without stubbing its boundary — e.g. #{stub_hint}.
          If this test drives the seam itself against fakes, lift the guard for its duration (allow_provisioning / restore_provisioning_guard).
        MSG
      end
    end
  end
end
