# typed: false
# frozen_string_literal: true

require "dev/provisioning_guard"

# Per-test opt-out of the provisioning kill-switch test_helper arms for the
# whole process (dev#208). Only a test that *drives an install seam itself*
# — against a fake brew/rbenv on PATH or a mocked Kernel.system — lifts the
# guard, and only for its own duration:
#
#   guard = allow_provisioning        # Given
#   ...
#   restore_provisioning_guard(guard) # Cleanup
#
# Every other test keeps the guard: a provisioning call it did not stub fails
# fast with ForbiddenError instead of building a Ruby.
module ProvisioningGuardHelper
  # Lifts the guard; returns the switch's prior value for restore.
  #
  # @return [String, nil]
  def allow_provisioning
    previous = ENV.fetch(Dev::ProvisioningGuard::ENV_VAR, nil)
    ENV.delete(Dev::ProvisioningGuard::ENV_VAR)
    previous
  end

  # Re-arms the guard exactly as it was before allow_provisioning.
  #
  # @param previous [String, nil] allow_provisioning's return
  # @return [void]
  def restore_provisioning_guard(previous)
    if previous.nil?
      ENV.delete(Dev::ProvisioningGuard::ENV_VAR)
    else
      ENV[Dev::ProvisioningGuard::ENV_VAR] = previous
    end
    nil
  end
end
