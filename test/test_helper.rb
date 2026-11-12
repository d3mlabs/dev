# typed: false
# frozen_string_literal: true

DEV_ROOT = File.expand_path("..", __dir__) unless defined?(DEV_ROOT)
$LOAD_PATH.unshift(File.join(DEV_ROOT, "lib")) unless $LOAD_PATH.include?(File.join(DEV_ROOT, "lib"))

require "sorbet-runtime"
require "dev"

# Minitest (load before mocha so MiniTest constant is available)
begin
  require "rubygems"
  gem "minitest"
rescue Gem::LoadError
  # do nothing
end

require "minitest"
MiniTest = Minitest # mocha/minitest expects the old name
require "minitest/spec"
require "minitest/mock"
require "mocha/minitest"
require "support/sorbet_helper"
require "support/provisioning_guard_helper"
require "support/host_probe_guard_helper"
require "support/parsed_args_helper"
require "support/value_semantics_assertions"
require "minitest/hell" if ENV["MT_HELL"]

# Arm the provisioning kill-switch for every test process (dev#208): a test
# that reaches a real install seam (brew install) without stubbing the
# boundary fails fast with ProvisioningGuard::ForbiddenError instead of
# installing on the developer's machine. Tests that drive a
# seam themselves lift it via ProvisioningGuardHelper.
ENV[Dev::ProvisioningGuard::ENV_VAR] = "1"
# And the host-probe kill-switch: a platform seam's default (`for_host`)
# answers per machine, so a test that reaches one is green here and red on
# the box, or the reverse. Armed, it fails on every host naming the seam to
# inject.
ENV[Dev::HostProbeGuard::ENV_VAR] = "1"
Minitest::Test.include(ProvisioningGuardHelper)
Minitest::Test.include(HostProbeGuardHelper)
Minitest::Test.include(ParsedArgsHelper)
Minitest::Test.include(ValueSemanticsAssertions)

# Minitest Reporters (optional; rspock uses RakeRerunReporter)
begin
  require "minitest/reporters"
  # require "minitest/reporters/rake_rerun_reporter"
  # Minitest::Reporters.use!([Minitest::Reporters::RakeRerunReporter.new])
  Minitest::Reporters.use!
rescue LoadError
  # minitest-reporters not installed
end

Minitest.autorun
