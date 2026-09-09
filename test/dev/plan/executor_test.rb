# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/plan/executor"

transform!(RSpock::AST::Transformation)
class Dev::Plan::ExecutorTest < Minitest::Test
  test "capture returns stdout, stderr, and success from a real process" do
    When "capturing a real shell command"
    out, err, ok = Dev::Plan::Executor.new.capture("sh", "-c", "echo out; echo err >&2")

    Then
    out == "out\n"
    err == "err\n"
    ok == true
  end

  test "capture pipes stdin data to the subprocess" do
    When "capturing with piped stdin"
    out, _err, ok = Dev::Plan::Executor.new.capture("cat", stdin: "piped payload")

    Then
    out == "piped payload"
    ok == true
  end

  test "capture reports a missing binary as a failure instead of raising" do
    When "capturing a command that does not exist"
    out, err, ok = Dev::Plan::Executor.new.capture("dev-test-missing-binary-xyz")

    Then "the ENOENT message rides the stderr slot"
    out == ""
    err.empty? == false
    ok == false
  end
end
