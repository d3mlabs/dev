# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/runner_slots"

transform!(RSpock::AST::Transformation)
class Dev::RunnerSlotsTest < Minitest::Test
  def slots(base: "mac1", dir: "/Users/op/actions-runner-ai-ask")
    Dev::RunnerSlots.new(base: base, dir: dir)
  end

  test "slot 1 is the bare name and slot n is `<base>-<n>`: an enrollment from before slots is slot 1 by construction" do
    Expect
    slots.slot_name(1) == "mac1"
    slots.slot_name(2) == "mac1-2"
    slots.slot_name(10) == "mac1-10"
  end

  test "a name #{name.inspect} is slot #{slot.inspect} of the mac1 slots" do
    Expect
    [slots.slot_of(name)] == [slot]
    slots.member?(name) == !slot.nil?

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
    Dev::RunnerSlots.base_of("mac1") == "mac1"
    Dev::RunnerSlots.base_of("mac1-2") == "mac1"
    Dev::RunnerSlots.base_of("build-box-3") == "build-box"
    Dev::RunnerSlots.base_of("mac1-0") == "mac1-0"
  end

  test "a base that itself ends in a slot-shaped suffix still owns its own slots" do
    Given "a host literally named build-2"
    named = slots(base: "build-2")

    Expect "its slots are build-2 and build-2-<n>; the build slots' 2 is not among them"
    named.slot_of("build-2") == 1
    named.slot_of("build-2-3") == 3
    named.member?("build-3") == false
  end

  test "slot dirs sit beside slot 1's, `-<n>` after it, wherever slot 1 lives" do
    Expect
    slots.slot_dir(1) == "/Users/op/actions-runner-ai-ask"
    slots.slot_dir(2) == "/Users/op/actions-runner-ai-ask-2"
    slots(dir: "/home/runner/actions-runner").slot_dir(3) == "/home/runner/actions-runner-3"
  end
end
