# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ByteSizeTest < Minitest::Test
  test "parse reads an integer with a binary unit, and to_s reads it back in the largest exact unit: #{text}" do
    Given
    size = Dev::Lifecycle::ByteSize.parse(text)

    Expect
    size.bytes == bytes
    size.to_s == rendered

    Where
    text      | bytes              | rendered
    "2GiB"    | 2 * 1024**3        | "2GiB"
    "500MiB"  | 500 * 1024**2      | "500MiB"
    "1536MiB" | 1536 * 1024**2     | "1536MiB"
    "1 KiB"   | 1024               | "1KiB"
    "1024"    | 1024               | "1KiB"
    "1000"    | 1000               | "1000"
    "3TiB"    | 3 * 1024**4        | "3TiB"
  end

  test "a string that is not a positive integer with one of the units is refused, listing them: #{text.inspect}" do
    When
    Dev::Lifecycle::ByteSize.parse(text)

    Then
    error = raises(Dev::Lifecycle::ByteSize::InvalidByteSizeError)
    error.message.include?(text.inspect)
    error.message.include?("B, KiB, MiB, GiB, TiB")

    Where
    text
    "2GB"
    "2 gib"
    "0"
    "-1MiB"
    "lots"
    ""
  end

  test "sizes are values" do
    Expect
    Dev::Lifecycle::ByteSize.parse("1GiB") == Dev::Lifecycle::ByteSize.parse("1024MiB")
    Dev::Lifecycle::ByteSize.parse("1GiB") != Dev::Lifecycle::ByteSize.parse("2GiB")
  end
end
