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
    @ui = Dev::Cli::UiImpl.new(cli_ui: @cli_ui)
  end

  test "#print_header formats and prints the command name" do
    When "we call print_header"
    @ui.print_header("./bin/setup.rb")

    Then "cli_ui.fmt is called for bold formatting and cli_ui.puts prints it"
    1 * @cli_ui.fmt("{{bold:./bin/setup.rb}}")
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
end
