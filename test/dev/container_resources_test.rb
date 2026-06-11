# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/container_resources"

transform!(RSpock::AST::Transformation)
class Dev::ContainerResourcesTest < Minitest::Test
  test "empty? is true only when neither dimension is declared" do
    Expect
    Dev::ContainerResources.new.empty?
    !Dev::ContainerResources.new(cpus: cpus, memory_gb: memory_gb).empty?

    Where
    cpus | memory_gb
    16   | nil
    nil  | 24
    16   | 24
  end

  test "shortfalls reports each dimension the host falls short on" do
    Given "a resource declaration"
    resources = Dev::ContainerResources.new(cpus: 16, memory_gb: 24)

    Expect "shortfalls match what the host lacks"
    resources.shortfalls(available_cpus: available_cpus, available_memory_gb: available_memory_gb).size == count

    Where
    available_cpus | available_memory_gb | count
    16             | 24                  | 0
    16             | 8                   | 1
    4              | 24                  | 1
    4              | 8                   | 2
  end

  test "shortfalls ignores undeclared dimensions" do
    Given "only memory is declared"
    resources = Dev::ContainerResources.new(memory_gb: 24)

    When "the host has plenty of memory but few cores"
    shortfalls = resources.shortfalls(available_cpus: 1, available_memory_gb: 32)

    Then "the undeclared cpu dimension is not reported"
    shortfalls == []
  end

  test "equality and hash compare both dimensions" do
    Given "two identical declarations"
    a = Dev::ContainerResources.new(cpus: 16, memory_gb: 24)
    b = Dev::ContainerResources.new(cpus: 16, memory_gb: 24)

    Expect
    a == b
    a.eql?(b)
    a.hash == b.hash
    a != Dev::ContainerResources.new(cpus: 8, memory_gb: 24)
  end
end
