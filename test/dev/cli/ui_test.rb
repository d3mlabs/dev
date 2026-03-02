# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/ui"

transform!(RSpock::AST::Transformation)
class Dev::Cli::UiImplTest < Minitest::Test
  include SorbetHelper

  def setup
    @cli_ui = typed_mock(CLI::UI, class_of: true)
    @cli_ui.stubs(:enable_color=)
    @out = typed_mock(IO)
    @ui = Dev::Cli::UiImpl.new(cli_ui: @cli_ui, out: @out)
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
    1 * @cli_ui.puts("#{::CLI::UI::Glyph::CHECK} Done")
  end
end

transform!(RSpock::AST::Transformation)
class Dev::Cli::NoUiTest < Minitest::Test
  test "#print_line writes to stdout" do
    Given "a NoUi instance"
    ui = Dev::Cli::NoUi.new

    Expect "print_line writes to stdout"
    assert_output("hello\n") { ui.print_line("hello") }
  end

  test "#done writes Done to stdout" do
    Given "a NoUi instance"
    ui = Dev::Cli::NoUi.new

    Expect "done writes Done"
    assert_output("Done\n") { ui.done }
  end
end
