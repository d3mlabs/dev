# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/runner_family"

transform!(RSpock::AST::Transformation)
class Dev::RunnerFamilyTest < Minitest::Test
  def family(base: "mac1", dir: "/Users/op/actions-runner-ai-ask")
    Dev::RunnerFamily.new(base: base, dir: dir)
  end

  test "slot 1 is the bare name and slot n is `<base>-<n>`: an enrollment from before slots is a family of one" do
    Expect
    family.slot_name(1) == "mac1"
    family.slot_name(2) == "mac1-2"
    family.slot_name(10) == "mac1-10"
  end

  test "a name #{name.inspect} is slot #{slot.inspect} of the mac1 family" do
    Expect
    [family.slot_of(name)] == [slot]
    family.member?(name) == !slot.nil?

    Where
    name        | slot
    "mac1"      | 1
    "mac1-2"    | 2
    "mac1-10"   | 10
    "mac1-0"    | nil
    "mac1-02"   | nil
    "mac1-x"    | nil
    "mac12"     | nil
    "mac1-2-3"  | nil
    "box"       | nil
  end

  test "base_of strips one slot suffix and leaves every other name whole" do
    Expect
    Dev::RunnerFamily.base_of("mac1") == "mac1"
    Dev::RunnerFamily.base_of("mac1-2") == "mac1"
    Dev::RunnerFamily.base_of("build-box-3") == "build-box"
    Dev::RunnerFamily.base_of("mac1-0") == "mac1-0"
  end

  test "a family whose base itself ends in a slot-shaped suffix still owns its own slots" do
    Given "a host literally named build-2"
    f = family(base: "build-2")

    Expect "its slots are build-2 and build-2-<n>; the build family's 2 is not its member"
    f.slot_of("build-2") == 1
    f.slot_of("build-2-3") == 3
    f.member?("build-3") == false
  end

  test "slot dirs sit beside slot 1's, `-<n>` after it, wherever slot 1 lives" do
    Expect
    family.slot_dir(1) == "/Users/op/actions-runner-ai-ask"
    family.slot_dir(2) == "/Users/op/actions-runner-ai-ask-2"
    family(dir: "/home/runner/actions-runner").slot_dir(3) == "/home/runner/actions-runner-3"
  end
end
