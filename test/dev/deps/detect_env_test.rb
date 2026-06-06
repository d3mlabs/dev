# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps"

transform!(RSpock::AST::Transformation)
class Dev::Deps::DetectEnvTest < Minitest::Test
  test "detect_env returns dev on macOS without CI" do
    Given "non-CI, non-Linux environment"
    original_ci = ENV["CI"]
    ENV.delete("CI")

    When "detecting env"
    result = Dev::Deps.detect_env

    Then "result depends on platform"
    if RUBY_PLATFORM.include?("linux")
      result == "ci"
    else
      result == "dev"
    end

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
end
