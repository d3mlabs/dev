# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/terminal_owner"

transform!(RSpock::AST::Transformation)
class Dev::TerminalOwnerTest < Minitest::Test
  test "outside a spinner the terminal is free: a claim passes and the block's value comes back" do
    When
    Dev::TerminalOwner.claim!("a child with the terminal")

    Then
    !Dev::TerminalOwner.spinning?
    Dev::TerminalOwner.spinning { :spun } == :spun
  end

  test "inside a spinner the terminal is the spinner's: a claim is refused naming the claimant, and the spin is noted while the block runs" do
    Given
    seen = []

    When
    error = assert_raises(Dev::TerminalOwner::UnderSpinnerError) do
      Dev::TerminalOwner.spinning do
        seen << Dev::TerminalOwner.spinning?
        Dev::TerminalOwner.claim!("sh -c ./bin/package")
      end
    end

    Then
    seen == [true]
    error.message == "sh -c ./bin/package would take the terminal under a spinner — a spinner captures stdout and masks stdin, " \
      "so its lines garble and its prompt hangs unseen; run it under `ui.step`, never `ui.spin`"
    !Dev::TerminalOwner.spinning?
  end

  test "the spin is released when the block raises, and a spinner under a spinner is itself refused" do
    When
    assert_raises(RuntimeError) { Dev::TerminalOwner.spinning { raise "boom" } }
    nested = assert_raises(Dev::TerminalOwner::UnderSpinnerError) do
      Dev::TerminalOwner.spinning { Dev::TerminalOwner.spinning { :never } }
    end

    Then
    !Dev::TerminalOwner.spinning?
    nested.message.start_with?("a spinner would take the terminal under a spinner")
  end

  test "the spin is this thread's: another thread's terminal is free" do
    When
    other = Dev::TerminalOwner.spinning { Thread.new { Dev::TerminalOwner.spinning? }.value }

    Then
    other == false
  end
end
