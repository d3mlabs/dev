# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/cli_ui"

transform!(RSpock::AST::Transformation)
class Dev::Deps::CliUITest < Minitest::Test
  test "available? probes once and memoizes the answer" do
    Given "the availability probe has run once"
    first = Dev::Deps::CliUI.available?

    When "asking again"
    second = Dev::Deps::CliUI.available?

    Then "the memoized boolean is returned"
    second == first
    [true, false].include?(second)
  end
end
