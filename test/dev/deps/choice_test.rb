# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/choice"
require "dev/deps/series_head"
require "dev/lifecycle/series"

transform!(RSpock::AST::Transformation)
class Dev::Deps::ChoiceTest < Minitest::Test
  def head(major, version)
    Dev::Deps::SeriesHead.new(series: Dev::Lifecycle::Series.new(major), version:)
  end

  test "a series head names the pointer and what it points at, as the lock report says it" do
    Expect
    head(1, "v1.3.0").to_s == "v1 → v1.3.0"
    Dev::Deps::Choice::Head.new(head: head(1, "v1.3.0")).to_s == "series head v1 → v1.3.0"
    Dev::Deps::Choice::Greatest.new.to_s == "greatest satisfying"
  end

  test "a head is the same head exactly when its series and version are" do
    Expect
    assert_value_semantics head(1, "v1.3.0"),
      equal_to: head(1, "v1.3.0"),
      unequal_to: [head(2, "v1.3.0"), head(1, "v1.4.0")]
  end

  test "choices compare by the rule and, for a head, by the head" do
    Expect
    assert_value_semantics Dev::Deps::Choice::Head.new(head: head(1, "v1.3.0")),
      equal_to: Dev::Deps::Choice::Head.new(head: head(1, "v1.3.0")),
      unequal_to: [Dev::Deps::Choice::Head.new(head: head(1, "v1.4.0")), Dev::Deps::Choice::Greatest.new]
    assert_value_semantics Dev::Deps::Choice::Greatest.new, equal_to: Dev::Deps::Choice::Greatest.new
  end
end
