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
end
