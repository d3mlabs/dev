# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::DeploymentStateTest < Minitest::Test
  test "#{word} parses to GitHub's state and reads as success? #{success} / failed? #{failed}" do
    Given
    state = Dev::Lifecycle::DeploymentState.parse(word)

    Expect
    state.to_s == word
    state.success? == success
    state.failed? == failed

    Where
    word          | success | failed
    "success"     | true    | false
    "failure"     | false   | true
    "error"       | false   | true
    "inactive"    | false   | false
    "in_progress" | false   | false
    "queued"      | false   | false
    "pending"     | false   | false
  end

  test "a word outside GitHub's set is refused with the set listed" do
    When
    Dev::Lifecycle::DeploymentState.parse("done")

    Then
    error = raises Dev::Lifecycle::UnknownDeploymentStateError
    error.message.include?('unknown deployment state "done" (expected success, failure, error, inactive, in_progress, queued, pending)')
  end
end
