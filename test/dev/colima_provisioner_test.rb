# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/colima_provisioner"
require "json"

# Records every colima invocation; the colima CLI is a true boundary. The VM
# it describes is a small state machine: absent, or present with a status and
# a size, plus the containers `docker ps` would list inside it.
class RecordedColimaExecutor
  attr_reader :runs

  GIB = 1024**3

  # @param vm [Hash, nil] { status: "Running" | "Stopped", cpus:, memory_gib: }, nil for no profile
  # @param containers [Array<String>] names `docker ps` inside the VM reports
  # @param start_ok [Boolean] whether `colima start` succeeds
  # @param stop_ok [Boolean] whether `colima stop` succeeds
  def initialize(vm: nil, containers: [], start_ok: true, stop_ok: true)
    @vm = vm
    @containers = containers
    @start_ok = start_ok
    @stop_ok = stop_ok
    @runs = []
  end

  def run(*cmd)
    @runs << cmd
    return @start_ok if cmd.first(2) == %w[colima start]
    return @stop_ok if cmd.first(2) == %w[colima stop]

    true
  end

  def quiet?(*cmd)
    @runs << cmd
    true
  end

  def capture(*cmd)
    case cmd
    when %w[colima list -j]
      return "" if @vm.nil?

      JSON.generate(
        "name" => "default", "status" => @vm[:status], "arch" => "aarch64",
        "cpus" => @vm[:cpus], "memory" => @vm[:memory_gib] * GIB, "disk" => 100 * GIB, "runtime" => "docker",
      ) + "\n"
    when ["colima", "ssh", "--", "docker", "ps", "--format", "{{.Names}}"]
      @containers.map { |name| "#{name}\n" }.join
    else
      ""
    end
  end
end unless defined?(RecordedColimaExecutor)

transform!(RSpock::AST::Transformation)
class Dev::ColimaProvisionerTest < Minitest::Test
  def start_cmd(cpus, memory_gib)
    ["colima", "start", "--cpu", cpus.to_s, "--memory", memory_gib.to_s, "--vm-type", "vz", "--vz-rosetta"]
  end

  # The recorded argvs, filtered by their `colima <verb>` prefix.
  def colima_runs(executor, verb)
    executor.runs.select { |bin, sub, *_rest| bin == "colima" && sub == verb }
  end

  def starts(executor) = colima_runs(executor, "start")
  def stops(executor) = colima_runs(executor, "stop")

  # --- no VM yet -----------------------------------------------------------

  test "no VM: provision! creates a default-sized vz VM with Rosetta" do
    Given "no colima profile"
    executor = RecordedColimaExecutor.new(vm: nil)

    When "provisioning without a hint"
    Dev::ColimaProvisioner.new(executor: executor).provision!

    Then "the start is vz + rosetta at the shipped defaults"
    starts(executor) == [start_cmd(Dev::ColimaProvisioner::DEFAULT_CPUS, Dev::ColimaProvisioner::DEFAULT_MEMORY_GIB)]
    stops(executor).empty?
  end

  test "no VM: provision! sizes the new VM from the repo's hint, per field" do
    Given "no colima profile"
    executor = RecordedColimaExecutor.new(vm: nil)

    When "provisioning with a hint"
    Dev::ColimaProvisioner.new(executor: executor).provision!(cpus: cpus, memory_gib: memory_gib)

    Then
    starts(executor) == [start_cmd(expected_cpus, expected_memory)]

    Where
    cpus | memory_gib | expected_cpus | expected_memory
    8    | 24         | 8             | 24
    6    | nil        | 6             | Dev::ColimaProvisioner::DEFAULT_MEMORY_GIB
    nil  | 16         | Dev::ColimaProvisioner::DEFAULT_CPUS | 16
  end

  # --- VM running ----------------------------------------------------------

  test "running and at least the hint: provision! touches nothing" do
    Given "a running 12/24 VM"
    executor = RecordedColimaExecutor.new(vm: { status: "Running", cpus: 12, memory_gib: 24 })

    When "provisioning with a hint the VM already meets"
    Dev::ColimaProvisioner.new(executor: executor).provision!(cpus: cpus, memory_gib: memory_gib)

    Then "no start, no stop — only the inspection"
    starts(executor).empty?
    stops(executor).empty?

    Where
    cpus | memory_gib
    12   | 24
    8    | 16
    nil  | nil
    nil  | 24
  end

  test "running, undersized, idle: provision! stops and restarts at the ratchet (max of current and hint)" do
    Given "a running 4/8 VM with no containers"
    executor = RecordedColimaExecutor.new(vm: { status: "Running", cpus: 4, memory_gib: 8 })

    When "a project needing 12 cpus but only 6 GiB provisions"
    Dev::ColimaProvisioner.new(executor: executor).provision!(cpus: 12, memory_gib: 6)

    Then "stop, then start at 12 cpus and the VM's own 8 GiB — sizes never shrink while running"
    stops(executor) == [%w[colima stop]]
    starts(executor) == [start_cmd(12, 8)]
    executor.runs.index(%w[colima stop]) < executor.runs.index(start_cmd(12, 8))
  end

  test "running, undersized, busy: provision! refuses and names the containers in the way" do
    Given "a running 4/8 VM with another project's service container up"
    executor = RecordedColimaExecutor.new(
      vm: { status: "Running", cpus: 4, memory_gib: 8 },
      containers: ["dev-snappy-linux-a1b2c3-content-9f8e", "dev-cellbound-3d-linux-d4e5f6-content-0a1b"],
    )

    When "a bigger project provisions"
    Dev::ColimaProvisioner.new(executor: executor).provision!(cpus: 12, memory_gib: 24)

    Then "a typed refusal; the VM is left exactly as it was"
    error = raises Dev::ColimaProvisioner::EngineBusyError
    error.message.include?("dev-snappy-linux-a1b2c3-content-9f8e")
    error.message.include?("dev-cellbound-3d-linux-d4e5f6-content-0a1b")
    error.message.include?("4 cpus / 8 GiB")
    error.message.include?("12 cpus / 24 GiB")
    stops(executor).empty?
    starts(executor).empty?
  end

  # --- VM stopped ----------------------------------------------------------

  test "stopped: provision! starts at exactly the hint — nobody is using a stopped VM, so it may shrink" do
    Given "a stopped 16/24 VM"
    executor = RecordedColimaExecutor.new(vm: { status: "Stopped", cpus: 16, memory_gib: 24 })

    When "a smaller project provisions"
    Dev::ColimaProvisioner.new(executor: executor).provision!(cpus: 8, memory_gib: 12)

    Then "no stop needed; the start carries the hint"
    stops(executor).empty?
    starts(executor) == [start_cmd(8, 12)]
  end

  test "stopped: a nil hint field keeps the VM's current value (no requirement is not a request to shrink)" do
    Given "a stopped 16/24 VM"
    executor = RecordedColimaExecutor.new(vm: { status: "Stopped", cpus: 16, memory_gib: 24 })

    When "provisioning"
    Dev::ColimaProvisioner.new(executor: executor).provision!(cpus: cpus, memory_gib: memory_gib)

    Then
    starts(executor) == [start_cmd(expected_cpus, expected_memory)]

    Where
    cpus | memory_gib | expected_cpus | expected_memory
    nil  | nil        | 16            | 24
    8    | nil        | 8             | 24
    nil  | 32         | 16            | 32
  end

  # --- failures ------------------------------------------------------------

  test "provision! raises when colima start fails" do
    Given "a start that fails"
    executor = RecordedColimaExecutor.new(vm: nil, start_ok: false)

    When "provisioning"
    Dev::ColimaProvisioner.new(executor: executor).provision!

    Then
    raises Dev::ColimaProvisioner::StartFailedError
  end

  test "provision! raises when the resize's colima stop fails, and does not start over a live VM" do
    Given "a running undersized idle VM whose stop fails"
    executor = RecordedColimaExecutor.new(vm: { status: "Running", cpus: 4, memory_gib: 8 }, stop_ok: false)

    When "provisioning bigger"
    Dev::ColimaProvisioner.new(executor: executor).provision!(cpus: 12)

    Then
    raises Dev::ColimaProvisioner::StopFailedError
    starts(executor).empty?
  end

  # --- the real executor ---------------------------------------------------
  # A thin wrapper over the process boundary; prove it with cheap real
  # processes, mirroring the ContainerEngine run/capture tests.

  test "Executor#run reports the child's success" do
    Given "the real executor"
    executor = Dev::ColimaProvisioner::Executor.new

    Expect "success and failure map to true/false"
    executor.run("true")
    !executor.run("false")
  end

  test "Executor#quiet? probes silently and survives a missing binary" do
    Given "the real executor"
    executor = Dev::ColimaProvisioner::Executor.new

    Expect "exit status maps to the boolean; ENOENT reads as not-running"
    executor.quiet?("true")
    !executor.quiet?("false")
    !executor.quiet?("dev-test-no-such-binary-#{Process.pid}")
  end

  test "Executor#capture returns stdout on success and empty output otherwise" do
    Given "the real executor"
    executor = Dev::ColimaProvisioner::Executor.new

    Expect
    executor.capture("echo", "hello") == "hello\n"
    executor.capture("false") == ""
    executor.capture("dev-test-no-such-binary-#{Process.pid}") == ""
  end
end
