# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/ui"

transform!(RSpock::AST::Transformation)
class Dev::Cli::UiTest < Minitest::Test
  extend T::Sig

  test "frame when TTY opens CLI::UI::Frame and yields" do
    Given "stdout is a TTY and Frame.open will yield"
    $stdout.stubs(:tty?).returns(true)
    yielded = false
    Dev::Cli::Ui.stubs(:ensure_enabled!)
    CLI::UI::Frame.expects(:open).with("My Title").yields

    When "we call frame with a block"
    Dev::Cli::Ui.frame("My Title") { yielded = true }

    Then "block was yielded to"
    assert yielded
  end

  test "frame when not TTY yields without opening frame" do
    Given "stdout is not a TTY and Frame.open is not to be called"
    $stdout.stubs(:tty?).returns(false)
    CLI::UI::Frame.expects(:open).never
    yielded = false

    When "we call frame with a block"
    Dev::Cli::Ui.frame("My Title") { yielded = true }

    Then "block was yielded to"
    assert yielded
  end

  test "fmt when TTY returns CLI::UI.fmt result" do
    Given "stdout is a TTY"
    $stdout.stubs(:tty?).returns(true)
    Dev::Cli::Ui.stubs(:ensure_enabled!)

    When "we call fmt"
    result = Dev::Cli::Ui.fmt("{{red:hi}}")
binding.pry
    Then "result is from CLI::UI.fmt"
    assert_equal "colored_hi", result
  end

  test "fmt when not TTY returns string unchanged" do
    Given "stdout is not a TTY"
    $stdout.stubs(:tty?).returns(false)

    When "we call fmt"
    result = Dev::Cli::Ui.fmt("{{red:hi}}")

    Then "result is the original string"
    assert_equal "{{red:hi}}", result
  end

  test "activate! when not TTY does not call ensure_enabled!" do
    Given "stdout is not a TTY"
    $stdout.stubs(:tty?).returns(false)

    When "we call activate!"
    Dev::Cli::Ui.activate!

    Then "ensure_enabled! is called"
    0 * Dev::Cli::Ui.ensure_enabled!
  end
end
