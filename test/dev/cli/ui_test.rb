# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/ui"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Cli::UiImplTest < Minitest::Test
  include SorbetHelper

  def setup
    @cli_ui = typed_mock(CLI::UI, class_of: true)
    @cli_ui.stubs(:enable_color=)
    @ui = Dev::Cli::UiImpl.new(cli_ui: @cli_ui)
  end

  test "#print_header formats and prints the command name" do
    When "we call print_header"
    @ui.print_header("./bin/setup.rb")

    Then "cli_ui.fmt is called for bold formatting and cli_ui.puts prints it"
    1 * @cli_ui.fmt("{{bold:./bin/setup.rb}}")
    1 * @cli_ui.puts(anything)
  end

  test "#print_remote_crossing prints the one dim line about leaving for a build host at a snapshot: #{destination}" do
    When
    @ui.print_remote_crossing(destination: destination, snapshot: "0123456789ab")

    Then
    1 * @cli_ui.fmt("{{gray:→ #{destination}, snapshot 0123456789ab}}")
    1 * @cli_ui.puts(anything)

    Where
    destination                   | _
    "on ue-engine-hosted"         | nil
    "in snappy-linux (container)" | nil
  end

  test "#ask_secret is CLI::UI's hidden-input prompt when a terminal is behind stdin, and nil (no question asked) when not" do
    Given "a prompt seam and two stdins"
    prompt = typed_mock(CLI::UI::Prompt, class_of: true)
    prompt.stubs(:ask_password).with("Token").returns("ghp_x")
    tty = StringIO.new
    tty.define_singleton_method(:tty?) { true }
    pipe = StringIO.new

    Expect
    Dev::Cli::UiImpl.new(cli_ui: @cli_ui, prompt: prompt, input: tty).ask_secret("Token") == "ghp_x"
    Dev::Cli::UiImpl.new(cli_ui: @cli_ui, prompt: prompt, input: pipe).ask_secret("Token").nil?
  end

  test "#frame is a timed CLI::UI frame around the block, answering what the block answered (dev#514)" do
    Given
    frame = typed_mock(CLI::UI::Frame, class_of: true)
    frame.expects(:open).with("Releasing v1.2.0", timing: true).yields.returns(42)
    ui = Dev::Cli::UiImpl.new(cli_ui: @cli_ui, frame: frame)
    ran = []

    Expect
    ui.frame("Releasing v1.2.0") { ran << 42 } == 42
    ran == [42]
  end

  test "#step runs the block under a CLI::UI spinner with no debrief; a raise marks the step failed and comes back out as itself (dev#514)" do
    Given "a spinner that runs the block, answering as CLI::UI does: true when it returned, false when it raised"
    spinner = typed_mock(CLI::UI::Spinner, class_of: true)
    spinner.stubs(:spin).with("Pushing main + tag v1.2.0", auto_debrief: false).returns(true).yields
    spinner.stubs(:spin).with("Creating GitHub release v1.2.0", auto_debrief: false).yields.returns(false)
    ui = Dev::Cli::UiImpl.new(cli_ui: @cli_ui, spinner: spinner)

    When
    pushed = ui.step("Pushing main + tag v1.2.0") { :pushed }
    error = assert_raises(RuntimeError) { ui.step("Creating GitHub release v1.2.0") { raise "HTTP 502" } }

    Then
    pushed == :pushed
    error.message == "HTTP 502"
  end

  test "#confirm asks CLI::UI's yes/no at a terminal, and is nil (nobody to ask) without one (dev#514)" do
    Given
    prompt = typed_mock(CLI::UI::Prompt, class_of: true)
    prompt.stubs(:confirm).with("Proceed?").returns(false)
    tty = StringIO.new
    tty.define_singleton_method(:tty?) { true }

    Expect
    Dev::Cli::UiImpl.new(cli_ui: @cli_ui, prompt: prompt, input: tty).confirm("Proceed?") == false
    Dev::Cli::UiImpl.new(cli_ui: @cli_ui, prompt: prompt, input: StringIO.new).confirm("Proceed?").nil?
  end

  test "#say prints the text through CLI::UI's formatting (dev#514)" do
    When
    @ui.say("{{v}} {{bold:v1.2.0 released!}}")

    Then
    1 * @cli_ui.fmt("{{v}} {{bold:v1.2.0 released!}}")
    1 * @cli_ui.puts(anything)
  end
end

transform!(RSpock::AST::Transformation)
class Dev::Cli::NoUiTest < Minitest::Test
  test "#print_header writes command name to stdout" do
    Given "a NoUi instance"
    ui = Dev::Cli::NoUi.new

    Expect "print_header writes the command name to stdout"
    assert_output("./bin/setup.rb\n") { ui.print_header("./bin/setup.rb") }
  end

  test "#print_remote_crossing writes the crossing line plain to stdout" do
    Given
    ui = Dev::Cli::NoUi.new

    Expect
    Dev::Cli::Ui::CROSSING_PREFIX == "→ "
    assert_output("→ on ue-engine-hosted, snapshot 0123456789ab\n") do
      ui.print_remote_crossing(destination: "on ue-engine-hosted", snapshot: "0123456789ab")
    end
  end

  test "#ask_secret never asks: nil, nothing written" do
    Given
    ui = Dev::Cli::NoUi.new

    Expect
    assert_output("") { assert_nil(ui.ask_secret("Token")) }
  end

  test "#frame, #step and #say are plain lines on the given stream: the title, a ✓ per step that returned, the text with its markup stripped (dev#514)" do
    Given
    out = StringIO.new
    ui = Dev::Cli::NoUi.new(out:)

    When
    answer = ui.frame("Releasing v1.2.0") do
      ui.say("{{bold:Base:}} main @ 6c8f60e")
      ui.step("Pushing main + tag v1.2.0") { :pushed }
    end
    ui.say("{{v}} {{bold:v1.2.0 released!}}")

    Then
    answer == :pushed
    out.string == "Releasing v1.2.0\nBase: main @ 6c8f60e\n✓ Pushing main + tag v1.2.0\n✓ v1.2.0 released!\n"
  end

  test "#step that raises writes ✗ and the raise comes back out as itself; #confirm is nil — nobody to ask (dev#514)" do
    Given
    out = StringIO.new
    ui = Dev::Cli::NoUi.new(out:)

    When
    error = assert_raises(RuntimeError) { ui.step("Creating GitHub release v1.2.0") { raise "HTTP 502" } }

    Then
    error.message == "HTTP 502"
    out.string == "✗ Creating GitHub release v1.2.0\n"
    ui.confirm("Proceed?").nil?
  end
end
