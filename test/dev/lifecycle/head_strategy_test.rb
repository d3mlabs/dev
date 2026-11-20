# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::HeadStrategyTest < Minitest::Test
  test "the strategy set is closed — a pointer deploy moves, or versions dev derives over — and spelled one way: #{id}" do
    Expect
    Dev::Lifecycle::HeadStrategy.deserialize(id) == strategy
    Dev::Lifecycle::HeadStrategy.parse(id) == strategy
    strategy.to_s == id
    strategy.serialize == id
    strategy.pointed? == pointed

    Where
    id        | strategy                                 | pointed
    "pointed" | Dev::Lifecycle::HeadStrategy::Pointed    | true
    "derived" | Dev::Lifecycle::HeadStrategy::Derived    | false
  end

  test "there are exactly the two strategies: a third is a decision to name here, never a publisher's special case" do
    Expect
    Dev::Lifecycle::HeadStrategy.values == [Dev::Lifecycle::HeadStrategy::Pointed, Dev::Lifecycle::HeadStrategy::Derived]
  end

  test "a word outside the set is refused with the set listed" do
    When
    Dev::Lifecycle::HeadStrategy.parse("latest")

    Then
    error = raises Dev::Lifecycle::UnknownHeadStrategyError
    error.message == 'unknown head strategy "latest" (expected pointed, derived)'
  end
end
