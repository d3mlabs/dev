# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/unlock_set"

transform!(RSpock::AST::Transformation)
class Dev::Deps::UnlockSetTest < Minitest::Test
  test "all floats every name and is not a subset — the bare verb's shape" do
    Given "the full re-lock"
    unlock = Dev::Deps::UnlockSet.all

    Expect
    unlock.all?
    !unlock.subset?
    unlock.floats?("anything")
    unlock.names == []
  end

  test "no names is all: there is no shape that floats nothing" do
    Expect
    Dev::Deps::UnlockSet.new.all?
    Dev::Deps::UnlockSet.new(names: []).all?
    Dev::Deps::UnlockSet.new == Dev::Deps::UnlockSet.all
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

  test "equal by value" do
    Expect
    Dev::Deps::UnlockSet.new(names: ["a"]) == Dev::Deps::UnlockSet.new(names: ["a"])
    Dev::Deps::UnlockSet.new(names: ["a"]).hash == Dev::Deps::UnlockSet.new(names: ["a"]).hash
    Dev::Deps::UnlockSet.all != Dev::Deps::UnlockSet.new(names: ["a"])
    Dev::Deps::UnlockSet.new(names: ["a"]) != Dev::Deps::UnlockSet.new(names: ["b"])
  end
end
