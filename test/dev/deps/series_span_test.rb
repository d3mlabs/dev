# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/series_span"
require "dev/lifecycle/series"

transform!(RSpock::AST::Transformation)
class Dev::Deps::SeriesSpanTest < Minitest::Test
  Series = Dev::Lifecycle::Series

  test "a bounded span covers the series from its floor up to, not including, its ceiling" do
    Given "series 1 and 2"
    span = Dev::Deps::SeriesSpan.new(from: Series.new(1), to: Series.new(3))

    Expect
    !span.covers?(Series.new(0))
    span.covers?(Series.new(1))
    span.covers?(Series.new(2))
    !span.covers?(Series.new(3))
    span.to_s == "v1..v3"
  end

  test "an open span covers every series from its floor on" do
    Given "series 2 and up"
    span = Dev::Deps::SeriesSpan.new(from: Series.new(2))

    Expect
    !span.covers?(Series.new(1))
    span.covers?(Series.new(2))
    span.covers?(Series.new(40))
    span.to_s == "v2.."
  end

  test "a span of one series reads as that series" do
    Expect
    Dev::Deps::SeriesSpan.new(from: Series.new(1), to: Series.new(2)).to_s == "v1"
  end

  test "a span whose ceiling is not above its floor covers nothing and is refused: v#{from}..v#{to}" do
    When
    Dev::Deps::SeriesSpan.new(from: Series.new(from), to: Series.new(to))

    Then
    raises Dev::Deps::SeriesSpan::EmptySpanError

    Where
    from | to
    1    | 1
    2    | 1
  end

  test "two spans are the same span exactly when their bounds are" do
    Expect
    assert_value_semantics Dev::Deps::SeriesSpan.new(from: Series.new(1), to: Series.new(2)),
      equal_to: Dev::Deps::SeriesSpan.new(from: Series.of("1.9.0"), to: Series.of("2.0.0")),
      unequal_to: [Dev::Deps::SeriesSpan.new(from: Series.new(1)), Dev::Deps::SeriesSpan.new(from: Series.new(1), to: Series.new(3))]
  end
end
