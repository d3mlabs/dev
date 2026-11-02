# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/tap_trust"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::TapTrustTest < Minitest::Test
  # Homebrew 7 loads nothing from a tap its user has not trusted, and trust
  # is per user: the step is the one thing both host bootstraps need
  # (RunnerUser on Linux, AgentBootstrap on macOS — dev#310, dev#374), and
  # how to run as the user is the one thing they hand it.
  test "trust! announces, then runs the brew dev found as the user with `trust --tap`" do
    Given "a tap and brew, and a run-as-user seam that records and succeeds"
    runs = []
    out = StringIO.new
    trust = Dev::TapTrust.new(
      user: "ai-agent", brew: "/opt/homebrew/bin/brew", tap: "d3mlabs/d3mlabs", out: out,
      run_as_user: recording(runs),
    )

    When
    trust.trust!

    Then "one invocation, by brew's path; the announcement, no warning"
    runs == [%w[/opt/homebrew/bin/brew trust --tap d3mlabs/d3mlabs]]
    out.string == ">>> Trusting the tap d3mlabs/d3mlabs for ai-agent (brew loads nothing from a tap its user has not trusted)\n"
  end

  test "a brew that refuses `trust` is a warning naming the by-hand command, not a stop" do
    Given "a run-as-user seam that fails (a brew without the command)"
    out = StringIO.new
    trust = Dev::TapTrust.new(
      user: "runner", brew: "/home/linuxbrew/.linuxbrew/bin/brew", tap: "d3mlabs/d3mlabs", out: out,
      run_as_user: ->(_argv) { false },
    )

    When
    trust.trust!

    Then
    out.string.include?("dev: warning: could not trust the tap d3mlabs/d3mlabs for runner")
    out.string.include?("`sudo -iu runner brew trust --tap d3mlabs/d3mlabs`")
  end

  test "nothing to trust without a tap, or without brew" do
    Given
    runs = []
    out = StringIO.new
    Dev::TapTrust.new(user: "runner", brew: "/opt/homebrew/bin/brew", tap: nil, out: out, run_as_user: recording(runs)).trust!
    Dev::TapTrust.new(user: "runner", brew: nil, tap: "d3mlabs/d3mlabs", out: out, run_as_user: recording(runs)).trust!

    Expect
    runs.empty?
    out.string.empty?
  end

  test "the deployment's tap is the user/repo of a tap-qualified formula; none for a bare name or no deployment" do
    Expect
    Dev::TapTrust.deployment_tap(formula: "d3mlabs/d3mlabs/dev") == "d3mlabs/d3mlabs"
    Dev::TapTrust.deployment_tap(formula: "dev-core").nil?
    Dev::TapTrust.deployment_tap(formula: nil).nil?
    [nil, %r{\A[^/]+/[^/]+\z}].any? { |shape| shape === Dev::TapTrust.deployment_tap }
  end

  private

  # A run-as-user seam that records every argv into +runs+ and succeeds.
  # A lambda, not a block: a one-parameter block is emitted as |argv,| by
  # the transform (rspockframework/ast-transform#21) and destructures an argv.
  def recording(runs)
    lambda do |argv|
      runs << argv
      true
    end
  end
end
