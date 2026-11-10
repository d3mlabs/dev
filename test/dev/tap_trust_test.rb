# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/tap_trust"
require "stringio"
require "support/recording_ui"

transform!(RSpock::AST::Transformation)
class Dev::TapTrustTest < Minitest::Test
  # Homebrew 7 loads nothing from a tap its user has not trusted, and trust
  # is per user: the step is the one thing both host bootstraps need
  # (RunnerUser on Linux, AgentBootstrap on macOS — dev#310, dev#374), and
  # how to run as the user is the one thing they hand it.
  test "trust! announces, then runs the brew dev found as the user with `trust --tap` — without brew's implicit auto-update (dev#475: its lock is the prefix owner's, and trust is a per-user file needing no API data)" do
    Given "a tap and brew, and a run-as-user seam that records and succeeds"
    runs = []
    ui = RecordingUi.new
    trust = Dev::TapTrust.new(
      user: "ai-agent", brew: "/opt/homebrew/bin/brew", tap: org_tap, ui: ui,
      run_as_user: recording(runs),
    )

    When
    trust.trust!

    Then "one invocation, by brew's path, auto-update off; one step (brew streams), no warning"
    runs == [%w[env HOMEBREW_NO_AUTO_UPDATE=1 /opt/homebrew/bin/brew trust --tap d3mlabs/d3mlabs]]
    ui.rows == [[:step, "Trusting the tap d3mlabs/d3mlabs for ai-agent (brew loads nothing from a tap its user has not trusted)", 0]]
  end

  test "a brew that refuses `trust` is a warning naming the by-hand command, not a stop: the step is marked failed, the note after it says what to do" do
    Given "a run-as-user seam that fails (a brew without the command)"
    ui = RecordingUi.new
    trust = Dev::TapTrust.new(
      user: "runner", brew: "/home/linuxbrew/.linuxbrew/bin/brew", tap: org_tap, ui: ui,
      run_as_user: ->(_argv) { false },
    )

    When
    trust.trust!

    Then
    ui.rows.length == 2
    ui.rows.fetch(0).fetch(0) == :step
    ui.rows.fetch(1).fetch(0) == :note
    ui.rows.fetch(1).fetch(1).start_with?("{{x}} could not trust the tap d3mlabs/d3mlabs for runner")
    ui.rows.fetch(1).fetch(1).include?("`sudo -iu runner brew trust --tap d3mlabs/d3mlabs`")
    ui.out_text.include?("✗ Trusting the tap d3mlabs/d3mlabs for runner")
  end

  test "nothing to trust without a tap, or without brew" do
    Given
    runs = []
    ui = RecordingUi.new
    Dev::TapTrust.new(user: "runner", brew: "/opt/homebrew/bin/brew", tap: nil, ui: ui, run_as_user: recording(runs)).trust!
    Dev::TapTrust.new(user: "runner", brew: nil, tap: org_tap, ui: ui, run_as_user: recording(runs)).trust!

    Expect
    runs.empty?
    ui.rows == []
  end

  test "the deployment's tap is the user/repo of a tap-qualified formula, as a Tap; none for a bare name, a malformed one, or no deployment" do
    Given
    tap = Dev::TapTrust.deployment_tap(formula: "d3mlabs/d3mlabs/dev")

    Expect
    tap.is_a?(Dev::TapTrust::Tap)
    tap.user == "d3mlabs"
    tap.repo == "d3mlabs"
    tap.to_s == "d3mlabs/d3mlabs"
    Dev::TapTrust.deployment_tap(formula: "dev-core").nil?
    Dev::TapTrust.deployment_tap(formula: "d3mlabs//dev").nil?
    Dev::TapTrust.deployment_tap(formula: nil).nil?
    [NilClass, Dev::TapTrust::Tap].any? { |shape| shape === Dev::TapTrust.deployment_tap }
  end

  private

  def org_tap
    Dev::TapTrust::Tap.new(user: "d3mlabs", repo: "d3mlabs")
  end

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
