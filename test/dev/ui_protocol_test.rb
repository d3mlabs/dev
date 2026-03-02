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
    @raw_out = StringIO.new
  end

  def build_protocol
    Dev::UiProtocol.new(ui: @ui, raw_out: @raw_out)
  end

  test "plain lines outside frames pass through to raw_out" do
    Given "a stream with no protocol markers"
    io = StringIO.new("hello world\ngoodbye\n")
    protocol = build_protocol

    When "we process the stream"
    protocol.process_stream(io)

    Then "each line is written directly to raw_out (bypass StdoutRouter)"
    assert_equal "hello world\ngoodbye\n", @raw_out.string
  end

  test "::frame:: opens a frame and ::endframe:: closes it" do
    Given "a stream with frame markers"
    io = StringIO.new("::frame::Build\nsome output\n::endframe::\n")
    protocol = build_protocol

    When "we process the stream"
    protocol.process_stream(io)

    Then "open_frame/close_frame are called, plain line goes through ui (gets frame borders)"
    1 * @ui.open_frame("Build")
    1 * @ui.print_line("some output")
    1 * @ui.close_frame("Build")
    assert_equal "", @raw_out.string
  end

  test "::ok:: renders a checkmark" do
    Given "a stream with an ok marker"
    io = StringIO.new("::ok::ccache\n")
    protocol = build_protocol

    When "we process the stream"
    protocol.process_stream(io)

    Then "ok is called with the label"
    1 * @ui.ok("ccache")
  end

  test "::fail:: renders an X" do
    Given "a stream with a fail marker"
    io = StringIO.new("::fail::cmake\n")
    protocol = build_protocol

    When "we process the stream"
    protocol.process_stream(io)

    Then "fail is called with the label"
    1 * @ui.fail("cmake")
  end

  test "::warn:: renders a warning" do
    Given "a stream with a warn marker"
    io = StringIO.new("::warn::lockfile changed\n")
    protocol = build_protocol

    When "we process the stream"
    protocol.process_stream(io)

    Then "warn is called with the message"
    1 * @ui.warn("lockfile changed")
  end

  test "::spin:: runs animated spinner until ::endspin::" do
    Given "a stream with spin/endspin markers"
    io = StringIO.new("::spin::Fetching boost\ndownloading...\n::endspin::\n")
    @ui.stubs(:with_spinner).yields
    protocol = build_protocol

    When "we process the stream"
    protocol.process_stream(io)

    Then "with_spinner is called with the label"
    1 * @ui.with_spinner("Fetching boost")
  end

  test "::spin:: with ::endspin::fail reports failure via spinner" do
    Given "a stream where the spinner fails"
    io = StringIO.new("::spin::Fetching boost\nerror!\n::endspin::fail\n")
    @ui.stubs(:with_spinner).yields
    protocol = build_protocol

    When "we process the stream"
    protocol.process_stream(io)

    Then "with_spinner is called with the label"
    1 * @ui.with_spinner("Fetching boost")
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
    protocol = build_protocol

    When "we process the stream"
    protocol.process_stream(io)

    Then "inner frame closes before outer frame, content goes through ui"
    1 * @ui.open_frame("Outer")
    1 * @ui.open_frame("Inner")
    1 * @ui.print_line("content")
    1 * @ui.close_frame("Inner")
    1 * @ui.close_frame("Outer")
    assert_equal "", @raw_out.string
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
    protocol = build_protocol

    When "we process the stream"
    protocol.process_stream(io)

    Then "markers and plain lines inside frame go through ui"
    1 * @ui.open_frame("Setup")
    1 * @ui.ok("step one")
    1 * @ui.print_line("plain output here")
    1 * @ui.fail("step two")
    1 * @ui.close_frame("Setup")
    assert_equal "", @raw_out.string
  end

  test "empty stream does nothing" do
    Given "an empty stream"
    io = StringIO.new("")
    protocol = build_protocol

    When "we process the stream"
    protocol.process_stream(io)

    Then "no ui methods are called and raw_out is empty"
    0 * @ui.open_frame(anything)
    assert_equal "", @raw_out.string
  end
end
