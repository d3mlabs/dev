# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/unlock_set"

transform!(RSpock::AST::Transformation)
class Dev::Deps::UnlockSetTest < Minitest::Test
  test "none floats nothing and is neither all nor a subset" do
    Given "the conservative re-lock"
    unlock = Dev::Deps::UnlockSet.none

    Expect
    !unlock.all?
    !unlock.subset?
    !unlock.floats?("cmake")
    unlock.names == []
  end

  test "named floats exactly the named declarations, once each" do
    Given "a subset re-lock naming two declarations, one twice"
    unlock = Dev::Deps::UnlockSet.new(names: ["gh", "cmake", "gh"])

    Expect
    unlock.subset?
    !unlock.all?
    unlock.floats?("gh")
    unlock.floats?("cmake")
    !unlock.floats?("python")
    unlock.names == ["gh", "cmake"]
  end

  test "all floats every name and is not a subset" do
    Given "the full re-lock"
    unlock = Dev::Deps::UnlockSet.all

    Expect
    unlock.all?
    !unlock.subset?
    unlock.floats?("anything")
  end

  test "equal by value" do
    Expect
    Dev::Deps::UnlockSet.new(names: ["a"]) == Dev::Deps::UnlockSet.new(names: ["a"])
    Dev::Deps::UnlockSet.new(names: ["a"]).hash == Dev::Deps::UnlockSet.new(names: ["a"]).hash
    Dev::Deps::UnlockSet.none == Dev::Deps::UnlockSet.new
    Dev::Deps::UnlockSet.all != Dev::Deps::UnlockSet.none
    Dev::Deps::UnlockSet.new(names: ["a"]) != Dev::Deps::UnlockSet.new(names: ["b"])
  end
end
