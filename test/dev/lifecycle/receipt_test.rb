# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ReceiptTest < Minitest::Test
  test "a receipt is the publisher's one line, compared by it" do
    Given
    receipt = Dev::Lifecycle::Receipt.new(summary: "build 1234567")

    Expect
    receipt.summary == "build 1234567"
    receipt.to_s == "build 1234567"
    receipt == Dev::Lifecycle::Receipt.new(summary: "build 1234567")
    receipt != Dev::Lifecycle::Receipt.new(summary: "build 7654321")
  end

  test "a receipt that says nothing is refused" do
    When
    Dev::Lifecycle::Receipt.new(summary: "  ")

    Then
    raises Dev::Lifecycle::Receipt::EmptyReceiptError
  end
end
