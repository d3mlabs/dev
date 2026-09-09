# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/locker"

transform!(RSpock::AST::Transformation)
class Dev::Deps::LockerTest < Minitest::Test
  test "base class lock raises NotImplementedError" do
    When "asking the abstract locker to solve a declaration set"
    Dev::Deps::Locker.new.lock([])

    Then
    raises NotImplementedError
  end
end
