# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps"

transform!(RSpock::AST::Transformation)
class Dev::Deps::DetectEnvTest < Minitest::Test
  test "detect_env returns dev without CI regardless of platform" do
    Given "no CI variable (a workstation — Linux ones included)"
    original_ci = ENV["CI"]
    ENV.delete("CI")

    When "detecting env"
    result = Dev::Deps.detect_env

    Then "the env is dev — platform no longer implies CI"
    result == "dev"

    Cleanup
    ENV["CI"] = original_ci if original_ci
  end

  test "detect_env returns ci when CI env var is set" do
    Given "CI=true"
    original_ci = ENV["CI"]
    ENV["CI"] = "true"

    When "detecting env"
    result = Dev::Deps.detect_env

    Then
    result == "ci"

    Cleanup
    ENV["CI"] = original_ci
  end

  test "detect_host reflects the current interpreter platform" do
    When "detecting the host OS"
    result = Dev::Deps.detect_host

    Then "the name matches RUBY_PLATFORM"
    if RUBY_PLATFORM.include?("darwin")
      result == "darwin"
    elsif RUBY_PLATFORM.include?("linux")
      result == "linux"
    else
      result == "windows"
    end
  end
end
