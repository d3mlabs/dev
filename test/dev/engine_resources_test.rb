# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_container_config"
require "dev/engine_resources"

transform!(RSpock::AST::Transformation)
class Dev::EngineResourcesTest < Minitest::Test
  test "satisfies? holds when every declared field is met; undeclared fields never bind" do
    Given "an engine of 12 cpus / 24 GiB"
    engine = Dev::EngineResources.new(cpus: 12, memory_gib: 24)

    Expect "each hint answers as its fields demand"
    engine.satisfies?(Dev::BuildContainerConfig::Resources.new(cpus: cpus, memory_gib: memory_gib)) == satisfied

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

  test "to_s reads as the operator would say it" do
    Expect
    Dev::EngineResources.new(cpus: 12, memory_gib: 24).to_s == "12 cpus / 24 GiB"
  end

  test "from_bytes rounds the daemon's MemTotal up to the GiB the VM was given (the guest kernel keeps some)" do
    Expect "25145466880 bytes — what a 24 GiB colima VM reports (23.4) — reads as 24; an exact size stays exact"
    Dev::EngineResources.from_bytes(cpus: 12, memory_bytes: 25_145_466_880).memory_gib == 24
    Dev::EngineResources.from_bytes(cpus: 4, memory_bytes: 8 * 1024**3).memory_gib == 8
  end
end
