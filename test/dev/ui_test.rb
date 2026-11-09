# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/ui"
require "dev/lifecycle"
require "dev/terminal_owner"
require "pathname"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::NoUiTest < Minitest::Test
  test "#print_header writes command name to stdout" do
    Given "a NoUi instance"
    ui = Dev::NoUi.new

    Expect "print_header writes the command name to stdout"
    assert_output("./bin/setup.rb\n") { ui.print_header("./bin/setup.rb") }
  end

  test "#print_remote_crossing writes the crossing line plain to stdout" do
    Given
    ui = Dev::NoUi.new

    Expect
    Dev::Ui::CROSSING_PREFIX == "→ "
    assert_output("→ on ue-engine-hosted, snapshot 0123456789ab\n") do
      ui.print_remote_crossing(destination: "on ue-engine-hosted", snapshot: "0123456789ab")
    end
  end

  test "#ask_secret never asks: nil, nothing written" do
    Given
    ui = Dev::NoUi.new

    Expect
    assert_output("") { assert_nil(ui.ask_secret("Token")) }
  end

  test "#frame, #spin, #step and #note are plain lines on the given stream, no escape codes: the title, ✓ per spin that returned, a step's name before and ✓ after, the text with its markup stripped (dev#514)" do
    Given
    out = StringIO.new
    ui = Dev::NoUi.new(out:)

    When
    answer = ui.frame("Releasing v1.2.0") do
      ui.note("{{bold:Base:}} main @ 6c8f60e")
      ui.spin("Pushing main + tag v1.2.0") { :pushed }
      ui.step("Packaging site") { out.puts("packaged site") }
      :done
    end
    ui.note("{{v}} {{bold:v1.2.0 released!}}")

    Then
    answer == :done
    out.string == "Releasing v1.2.0\nBase: main @ 6c8f60e\n✓ Pushing main + tag v1.2.0\nPackaging site\npackaged site\n✓ Packaging site\n✓ v1.2.0 released!\n"
    !out.string.include?("\e[")
  end

  test "#spin and #step that raise write ✗ and the raise comes back out as itself; #confirm is nil — nobody to ask (dev#514)" do
    Given
    out = StringIO.new
    ui = Dev::NoUi.new(out:)

    When
    spun = assert_raises(RuntimeError) { ui.spin("Creating GitHub release v1.2.0") { raise "HTTP 502" } }
    stepped = assert_raises(RuntimeError) { ui.step("Shipping via run: sh ./stage.sh") { raise "exited 7" } }

    Then
    spun.message == "HTTP 502"
    stepped.message == "exited 7"
    out.string == "✗ Creating GitHub release v1.2.0\nShipping via run: sh ./stage.sh\n✗ Shipping via run: sh ./stage.sh\n"
    ui.confirm("Proceed?").nil?
  end

  test "the plain tier keeps the spinner's rule too: a child with inherited stdio under #spin is refused — so a test catches the misuse the terminal would (plans#52)" do
    Given
    ui = Dev::NoUi.new(out: StringIO.new)

    When
    error = assert_raises(Dev::TerminalOwner::UnderSpinnerError) do
      ui.spin("Packaging site") { Dev::Lifecycle::Shell.new.run(["true"], chdir: Pathname(Dir.pwd)) }
    end

    Then
    error.message.start_with?("`true` would take the terminal under a spinner")
    !Dev::TerminalOwner.spinning?
  end
end
