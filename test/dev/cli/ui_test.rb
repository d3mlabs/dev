# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/ui"


transform!(RSpock::AST::Transformation)
class Dev::Cli::UiImplTest < Minitest::Test
  include SorbetHelper

  def setup
    @cli_ui = typed_mock(CLI::UI, class_of: true)
    @cli_ui.stubs(:enable)
    @cli_ui.stubs(:enable_color=)
    @out = typed_mock(IO)
    @ui = Dev::Cli::UiImpl.new(cli_ui: @cli_ui, out: @out)
  end

  test "#frame delegates to CLI::UI.frame" do
    Given "a block to forward"
    proc = Proc.new { }

    When "we call frame with that block"
    @ui.frame("Build", &proc)

    Then "we delegate to CLI::UI.frame with the same block"
    1 * @cli_ui.frame("Build", to: @out, &proc)
  end

  test "#fmt delegates to CLI::UI.fmt" do
    Given "a string to be formatted"
    str = "{{red:error}}"
    expected = "formatted"

    When "we call fmt"
    result = @ui.fmt(str)

    Then "we delegate to CLI::UI.fmt"
    1 * @cli_ui.fmt(str) >> expected
    result == expected
  end

  test "#with_spinner delegates to cli_ui.spinner with title, out and block" do
    Given "a block to forward"
    proc = Proc.new { }

    When "we call with_spinner with that block"
    @ui.with_spinner("Loading", &proc)

    Then "cli_ui.spinner is called with the title, out and same block"
    1 * @cli_ui.spinner("Loading", to: @out, &proc)
  end

  test "#print_line delegates to cli_ui.puts with message and out" do
    When "we call print_line"
    @ui.print_line("hello")

    Then "cli_ui.puts is called with the message and out"
    1 * @cli_ui.puts("hello", to: @out)
  end

  test "#done prints check glyph via cli_ui.puts" do
    When "we call done"
    @ui.done

    Then "cli_ui.puts is called with the check glyph message"
    1 * @cli_ui.puts("#{::CLI::UI::Glyph::CHECK.to_s} Done")
  end
end

transform!(RSpock::AST::Transformation)
class Dev::Cli::NoUiTest < Minitest::Test
  test "#frame yields without external calls" do
    Given "a NoUi instance"
    ui = Dev::Cli::NoUi.new
    yielded = false

    When "we call frame"
    ui.frame("Title") { yielded = true }

    Then "the block was yielded"
    assert yielded
  end

  test "#fmt returns the string unchanged" do
    Expect "the string passes through"
    Dev::Cli::NoUi.new.fmt("{{red:hi}}") == "{{red:hi}}"
  end
end
