# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/engine_resources"

transform!(RSpock::AST::Transformation)
class Dev::EngineResourcesTest < Minitest::Test
  test "satisfies? holds when every declared field is met; undeclared fields never bind" do
    Given "an engine of 12 cpus / 24 GiB"
    engine = Dev::EngineResources.new(cpus: 12, memory_gib: 24)

    Expect "each hint answers as its fields demand"
    engine.satisfies?(Dev::EngineResources::Hint.new(cpus: cpus, memory_gib: memory_gib)) == satisfied

    Where
    cpus | memory_gib | satisfied
    12   | 24         | true
    8    | 16         | true
    16   | 24         | false
    12   | 32         | false
    nil  | 24         | true
    nil  | 25         | false
    16   | nil        | false
    nil  | nil        | true
  end

  test "satisfies? treats a nil hint as no requirement" do
    Given "any engine"
    engine = Dev::EngineResources.new(cpus: 1, memory_gib: 1)

    Expect
    engine.satisfies?(nil)
  end

  test "it is a value: equal sizes are one Hash key" do
    Given "two readings of the same size and one of another"
    a = Dev::EngineResources.new(cpus: 12, memory_gib: 24)
    b = Dev::EngineResources.new(cpus: 12, memory_gib: 24)
    c = Dev::EngineResources.new(cpus: 12, memory_gib: 16)

    Expect
    a.eql?(b)
    a.hash == b.hash
    !a.eql?(c)
    { a => :seen }.key?(b)
    [a, b, c].uniq.size == 2
  end

  test "to_s reads as the operator would say it" do
    Expect
    Dev::EngineResources.new(cpus: 12, memory_gib: 24).to_s == "12 cpus / 24 GiB"
  end

  test "Hint is the repo's floor: every field optional, a value by its fields" do
    Given "two identical hints, one differing only by disk, and an empty one"
    a = Dev::EngineResources::Hint.new(cpus: 8, memory_gib: 24, disk_gib: 250)
    b = Dev::EngineResources::Hint.new(cpus: 8, memory_gib: 24, disk_gib: 250)
    c = Dev::EngineResources::Hint.new(cpus: 8, memory_gib: 24)
    empty = Dev::EngineResources::Hint.new

    Expect
    a == b
    a.eql?(b)
    a.hash == b.hash
    a != c
    { a => :seen }.key?(b)
    empty.cpus.nil? && empty.memory_gib.nil? && empty.disk_gib.nil?
  end

  test "from_bytes rounds the daemon's MemTotal up to the GiB the VM was given (the guest kernel keeps some)" do
    Expect "25145466880 bytes — what a 24 GiB colima VM reports (23.4) — reads as 24; an exact size stays exact"
    Dev::EngineResources.from_bytes(cpus: 12, memory_bytes: 25_145_466_880).memory_gib == 24
    Dev::EngineResources.from_bytes(cpus: 4, memory_bytes: 8 * 1024**3).memory_gib == 8
  end
end
