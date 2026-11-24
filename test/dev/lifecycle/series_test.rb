# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::SeriesTest < Minitest::Test
  test "a version belongs to the series of its major, whatever its spelling: #{version} → #{name}" do
    Expect
    Dev::Lifecycle::Series.of(version).to_s == name
    Dev::Lifecycle::Series.of(version).major == major
    Dev::Lifecycle::Series.new(major).includes?(version)
    !Dev::Lifecycle::Series.new(major + 1).includes?(version)

    Where
    version       | major | name
    "1.2.0"       | 1     | "v1"
    "2.0.0"       | 2     | "v2"
    "0.8.14"      | 0     | "v0"
    "1.0.0-rc.1"  | 1     | "v1"
    "1.0.0.pre.1" | 1     | "v1"
    "10.3"        | 10    | "v10"
  end

  test "a word that is not a version belongs to no series: #{word.inspect}" do
    When
    Dev::Lifecycle::Series.of(word)

    Then
    error = raises Dev::Lifecycle::Series::NotAVersionError
    error.message == "#{word.inspect} is not a version, so it belongs to no series"
    !Dev::Lifecycle::Series.version?(word)

    Where
    word
    "v1.2.0"
    "latest"
    "toolchain-2"
    "1..2"
    ""
  end

  test "a series tag is v and a bare major, and names that series: #{tag.inspect}" do
    Expect
    Dev::Lifecycle::Series.tag?(tag)
    Dev::Lifecycle::Series.of_tag(tag) == Dev::Lifecycle::Series.new(major)
    Dev::Lifecycle::Series.of_tag(tag).to_s == tag

    Where
    tag   | major
    "v0"  | 0
    "v1"  | 1
    "v12" | 12
  end

  test "a tag that is not a series tag names no series: #{tag.inspect}" do
    When
    Dev::Lifecycle::Series.of_tag(tag)

    Then
    error = raises Dev::Lifecycle::Series::NotASeriesTagError
    error.message == "#{tag.inspect} is not a series tag (v<major>)"
    !Dev::Lifecycle::Series.tag?(tag)

    Where
    tag
    "v1.2.0"
    "1"
    "V1"
    "latest"
    "v1-rc"
    ""
  end

  test "a series is a major, zero or more" do
    When
    Dev::Lifecycle::Series.new(-1)

    Then
    raises Dev::Lifecycle::Series::NegativeMajorError
  end

  test "two series are the same series exactly when their majors are" do
    Expect
    assert_value_semantics Dev::Lifecycle::Series.new(1),
      equal_to: Dev::Lifecycle::Series.of("1.9.9"),
      unequal_to: [Dev::Lifecycle::Series.new(2), Dev::Lifecycle::Series.of("0.1.0")]
    Dev::Lifecycle::Series.new(1).frozen?
  end
end
