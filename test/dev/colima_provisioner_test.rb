# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/colima_provisioner"

# Records every colima invocation; the colima CLI is a true boundary.
class RecordedColimaExecutor
  attr_reader :runs, :probes

  def initialize(running: false, start_ok: true)
    @running = running
    @start_ok = start_ok
    @runs = []
    @probes = []
  end

  def run(*cmd)
    @runs << cmd
    @start_ok
  end

  def quiet?(*cmd)
    @probes << cmd
    @running
  end
end unless defined?(RecordedColimaExecutor)

transform!(RSpock::AST::Transformation)
class Dev::ColimaProvisionerTest < Minitest::Test
  test "provision! is a no-op when the VM is already running (idempotent)" do
    Given "colima status reporting a running VM"
    executor = RecordedColimaExecutor.new(running: true)

    When "provisioning"
    Dev::ColimaProvisioner.new(executor: executor).provision!

    Then "only the status probe ran"
    executor.probes == [["colima", "status"]]
    executor.runs.empty?
  end

  test "provision! starts a default-sized vz VM with Rosetta when none runs" do
    Given "colima status reporting no VM"
    executor = RecordedColimaExecutor.new(running: false)

    When "provisioning without a sizing hint"
    Dev::ColimaProvisioner.new(executor: executor).provision!

    Then "the start is vz + rosetta at the shipped defaults"
    executor.runs == [[
      "colima", "start",
      "--cpu", Dev::ColimaProvisioner::DEFAULT_CPUS.to_s,
      "--memory", Dev::ColimaProvisioner::DEFAULT_MEMORY_GIB.to_s,
      "--vm-type", "vz", "--vz-rosetta",
    ]]
  end

  test "provision! sizes the VM from the repo's resources hint" do
    Given "colima status reporting no VM"
    executor = RecordedColimaExecutor.new(running: false)

    When "provisioning with a sizing hint"
    Dev::ColimaProvisioner.new(executor: executor).provision!(cpus: 8, memory_gib: 24)

    Then
    executor.runs == [[
      "colima", "start", "--cpu", "8", "--memory", "24", "--vm-type", "vz", "--vz-rosetta",
    ]]
  end

  test "a half-declared hint falls back per field" do
    Given "colima status reporting no VM"
    executor = RecordedColimaExecutor.new(running: false)

    When "provisioning with only cpus pinned"
    Dev::ColimaProvisioner.new(executor: executor).provision!(cpus: 6)

    Then
    executor.runs.first.include?("6")
    executor.runs.first.include?(Dev::ColimaProvisioner::DEFAULT_MEMORY_GIB.to_s)
  end

  test "provision! raises when colima start fails" do
    Given "a start that fails"
    executor = RecordedColimaExecutor.new(running: false, start_ok: false)

    When "provisioning"
    Dev::ColimaProvisioner.new(executor: executor).provision!

    Then
    raises Dev::ColimaProvisioner::StartFailedError
  end
end
