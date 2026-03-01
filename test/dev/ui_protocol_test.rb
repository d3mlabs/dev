# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/ui_protocol"
require "stringio"

transform!(RSpock::AST::Transformation)
class UiProtocolTest < Minitest::Test
  extend T::Sig
  include SorbetHelper

  def setup
    @ui = typed_mock(Dev::Cli::Ui)
  end

  test "plain lines pass through via print_line" do
    Given "a stream with no protocol markers"
    io = StringIO.new("hello world\ngoodbye\n")
    protocol = Dev::UiProtocol.new(ui: @ui)

    When "we process the stream"
    protocol.process_stream(io)

    Then "each line is passed to print_line"
    1 * @ui.print_line("hello world")
    1 * @ui.print_line("goodbye")
  end

  test "::frame:: opens a frame and ::endframe:: closes it" do
    Given "a stream with frame markers"
    io = StringIO.new("::frame::Build\nsome output\n::endframe::\n")
    protocol = Dev::UiProtocol.new(ui: @ui)

    When "we process the stream"
    protocol.process_stream(io)

    Then "open_frame and close_frame are called"
    1 * @ui.open_frame("Build")
    1 * @ui.print_line("some output")
    1 * @ui.close_frame("Build")
  end

  test "::ok:: renders a checkmark" do
    Given "a stream with an ok marker"
    io = StringIO.new("::ok::ccache\n")
    protocol = Dev::UiProtocol.new(ui: @ui)

    When "we process the stream"
    protocol.process_stream(io)

    Then "ok is called with the label"
    1 * @ui.ok("ccache")
  end

  test "::fail:: renders an X" do
    Given "a stream with a fail marker"
    io = StringIO.new("::fail::cmake\n")
    protocol = Dev::UiProtocol.new(ui: @ui)

    When "we process the stream"
    protocol.process_stream(io)

    Then "fail is called with the label"
    1 * @ui.fail("cmake")
  end

  test "::warn:: renders a warning" do
    Given "a stream with a warn marker"
    io = StringIO.new("::warn::lockfile changed\n")
    protocol = Dev::UiProtocol.new(ui: @ui)

    When "we process the stream"
    protocol.process_stream(io)

    Then "warn is called with the message"
    1 * @ui.warn("lockfile changed")
  end

  test "::spin:: drains lines until ::endspin:: and reports ok" do
    Given "a stream with spin/endspin markers"
    io = StringIO.new("::spin::Fetching boost\ndownloading...\n::endspin::\n")
    protocol = Dev::UiProtocol.new(ui: @ui)

    When "we process the stream"
    protocol.process_stream(io)

    Then "ok is called with the spin label"
    1 * @ui.ok("Fetching boost")
  end

  test "::spin:: with ::endspin::fail reports failure" do
    Given "a stream where the spinner fails"
    io = StringIO.new("::spin::Fetching boost\nerror!\n::endspin::fail\n")
    protocol = Dev::UiProtocol.new(ui: @ui)

    When "we process the stream"
    protocol.process_stream(io)

    Then "fail is called with the spin label"
    1 * @ui.fail("Fetching boost")
  end

  test "nested frames track correctly" do
    Given "a stream with nested frames"
    io = StringIO.new(<<~PROTO)
      ::frame::Outer
      ::frame::Inner
      content
      ::endframe::
      ::endframe::
    PROTO
    protocol = Dev::UiProtocol.new(ui: @ui)

    When "we process the stream"
    protocol.process_stream(io)

    Then "inner frame closes before outer frame"
    1 * @ui.open_frame("Outer")
    1 * @ui.open_frame("Inner")
    1 * @ui.print_line("content")
    1 * @ui.close_frame("Inner")
    1 * @ui.close_frame("Outer")
  end

  test "mixed protocol and plain output" do
    Given "a stream mixing markers and plain text"
    io = StringIO.new(<<~PROTO)
      ::frame::Setup
      ::ok::step one
      plain output here
      ::fail::step two
      ::endframe::
    PROTO
    protocol = Dev::UiProtocol.new(ui: @ui)

    When "we process the stream"
    protocol.process_stream(io)

    Then "all markers and plain lines are dispatched correctly"
    1 * @ui.open_frame("Setup")
    1 * @ui.ok("step one")
    1 * @ui.print_line("plain output here")
    1 * @ui.fail("step two")
    1 * @ui.close_frame("Setup")
  end

  test "empty stream does nothing" do
    Given "an empty stream"
    io = StringIO.new("")
    protocol = Dev::UiProtocol.new(ui: @ui)

    When "we process the stream"
    protocol.process_stream(io)

    Then "no ui methods are called"
    0 * @ui.print_line(anything)
    0 * @ui.open_frame(anything)
  end
end
