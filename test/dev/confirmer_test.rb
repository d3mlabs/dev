# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/confirmer"
require "stringio"

# A terminal stand-in: StringIO content with tty? answering true, so the
# interactive branch is exercised without a pty.
class FakeTtyInput < StringIO
  def tty?
    true
  end
end unless defined?(FakeTtyInput)

transform!(RSpock::AST::Transformation)
class Dev::ConfirmerTest < Minitest::Test
  test "on a terminal, confirm? prints the question with a [y/N] cue and reads the answer: #{description}" do
    Given "a terminal that will answer #{answer.inspect}"
    out = StringIO.new
    confirmer = Dev::Confirmer.new(input: FakeTtyInput.new(answer), out: out)

    When "asking"
    result = confirmer.confirm?("stop these too?")

    Then
    result == expected
    out.string == "stop these too? [y/N] "

    Where
    description          | answer   | expected
    "yes"                | "y\n"    | true
    "Yes, spelled out"   | "Yes\n"  | true
    "no"                 | "n\n"    | false
    "empty is the default, no" | "\n" | false
    "end of input is no" | ""       | false
  end

  test "off a terminal, confirm? is no without asking — a script cannot answer" do
    Given "a non-interactive stdin that would have said yes"
    out = StringIO.new
    confirmer = Dev::Confirmer.new(input: StringIO.new("y\n"), out: out)

    Expect "no, and nothing printed"
    confirmer.confirm?("stop these too?") == false
    out.string == ""
  end
end
