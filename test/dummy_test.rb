# frozen_string_literal: true

require "test_helper"

transform!(RSpock::AST::Transformation)
class DummyTest < Minitest::Test
  test "dummy test passes" do
    Expect "true is true"
    true == true
  end
end
