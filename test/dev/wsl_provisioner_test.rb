# typed: false
# frozen_string_literal: true

require "test_helper"
require "support/recorded_wsl_executor"
require "dev/wsl_provisioner"
require "stringio"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class Dev::WslProvisionerTest < Minitest::Test
  GIB = 1024**3

  def setup
    @dir = Dir.mktmpdir("wsl-prov-test-")
    @profile = File.join(@dir, "profile")
    FileUtils.mkdir_p(@profile)
    @binfmt = File.join(@dir, "binfmt_misc")
    FileUtils.mkdir_p(@binfmt)
    @out = StringIO.new
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def wslconfig_path
    File.join(@profile, ".wslconfig")
  end

  def wslconfig
    File.exist?(wslconfig_path) ? File.read(wslconfig_path) : nil
  end

  # A provisioner over a real WslHost whose boundaries are the recorded
  # executor and real temp files: the VM runs at +observed+ (cpus, GiB), the
  # Windows box has +hardware+, and +config+ is the current .wslconfig text
  # (nil for no file).
  def provisioner(config: nil, observed: [4, 8], hardware: [28, 64], containers: [], interop: true)
    File.write(wslconfig_path, config) if config
    File.write(File.join(@binfmt, "WSLInterop"), "enabled\n") if interop
    cpus, memory_gib = observed
    hw_cpus, hw_gib = hardware
    executor = RecordedWslExecutor.new(
      profile_dir: @profile, nproc: cpus.to_s, hardware: "#{hw_cpus} #{hw_gib * GIB}", containers: containers,
    )
    meminfo = File.join(@dir, "meminfo")
    File.write(meminfo, "MemTotal:       #{memory_gib * GIB / 1024} kB\n")
    host = Dev::WslHost.new(
      executor: executor, host_os: "linux", proc_version_path: File.join(@dir, "version"),
      binfmt_dir: @binfmt, meminfo_path: meminfo,
    )
    [Dev::WslProvisioner.new(host: host, executor: executor, out: @out), executor]
  end

  test "no .wslconfig and WSL defaults already big enough: only autoMemoryReclaim is written, no restart" do
    Given "a fresh machine whose default VM meets the hint"
    prov, _executor = provisioner(config: nil, observed: [28, 32])

    When "provisioning"
    prov.provision!(cpus: cpus, memory_gib: memory_gib)

    Then "a default that satisfies the project is not pinned; the reclaim mode is"
    wslconfig == "[experimental]\nautoMemoryReclaim=gradual\n"

    Cleanup
    nil

    Where
    cpus | memory_gib
    12   | 24
    nil  | 24
    12   | nil
  end

  test "no .wslconfig and a default too small in one field: writes that field only, leaves the other unset" do
    Given "a fresh machine with few cpus but plenty of memory by default"
    prov, _executor = provisioner(config: nil, observed: [4, 32])

    When "provisioning"
    error = assert_raises(Dev::WslProvisioner::RestartRequiredError) { prov.provision!(cpus: 12, memory_gib: 24) }

    Then "processors are written, memory stays at WSL's default, and the restart is requested"
    wslconfig == "[wsl2]\nprocessors=12\n\n[experimental]\nautoMemoryReclaim=gradual\n"
    error.message.include?("12 cpus / 32 GiB")

    Cleanup
    nil
  end

  test "no .wslconfig and a VM smaller than the hint: writes the hint and asks for the restart" do
    Given "a fresh machine whose default VM is too small"
    prov, _executor = provisioner(config: nil, observed: [4, 8])

    When "provisioning"
    error = assert_raises(Dev::WslProvisioner::RestartRequiredError) { prov.provision!(cpus: 12, memory_gib: 24) }

    Then "the file is written and the message names wsl --shutdown and the sizes"
    wslconfig == "[wsl2]\nprocessors=12\nmemory=24GB\n\n[experimental]\nautoMemoryReclaim=gradual\n"
    error.message.include?("wsl --shutdown")
    error.message.include?("12 cpus / 24 GiB")
    error.message.include?("4 cpus / 8 GiB")

    Cleanup
    nil
  end

  test "configured at or above the hint and applied: no-op, nothing written" do
    Given "a 28/64 box, converged, whose VM reports a GiB less than configured (the guest kernel's share)"
    text = "[wsl2]\nmemory=64GB\nprocessors=28\nswap=16GB\nnetworkingMode=mirrored\n\n[experimental]\nautoMemoryReclaim=gradual\n"
    prov, executor = provisioner(config: text, observed: [28, observed_gib])

    When "a smaller project provisions"
    prov.provision!(cpus: 12, memory_gib: 24)

    Then "the file is untouched and docker ps was never consulted"
    wslconfig == text
    executor.runs.none? { |bin, *_rest| bin == "docker" }

    Cleanup
    nil

    Where
    observed_gib | _
    64           | nil
    63           | nil
  end

  test "the gamebox's actual first run: reclaim under [wsl2] (ignored by WSL), VM at 63 of 64 GiB — fixed, no restart" do
    Given "the file the gamebox had, and the VM it had"
    text = "[wsl2]\nmemory=64GB\nprocessors=28\nswap=16GB\nautoMemoryReclaim=gradual\nnetworkingMode=mirrored\n"
    prov, _executor = provisioner(config: text, observed: [28, 63])

    When "cellbound-3d provisions"
    prov.provision!(cpus: 12, memory_gib: 24)

    Then "the reclaim mode is written where WSL reads it, the stray line is left alone, and nothing asks for a restart"
    wslconfig == "#{text}\n[experimental]\nautoMemoryReclaim=gradual\n"

    Cleanup
    nil
  end

  test "a hint equal to the configured size is met by a VM a GiB short of it — never a perpetual restart" do
    Given "a 64 GB config, a 63 GiB VM, and a project asking for all 64"
    text = "[wsl2]\nprocessors=28\nmemory=64GB\n\n[experimental]\nautoMemoryReclaim=gradual\n"
    prov, _executor = provisioner(config: text, observed: [28, 63])

    When "provisioning"
    prov.provision!(cpus: 28, memory_gib: 64)

    Then "nothing to do"
    wslconfig == text

    Cleanup
    nil
  end

  test "configured above the hint but the VM still runs the old size: restart pending, nothing rewritten" do
    Given "a resize that was written but never applied"
    text = "[wsl2]\nprocessors=12\nmemory=24GB\n\n[experimental]\nautoMemoryReclaim=gradual\n"
    prov, _executor = provisioner(config: text, observed: [4, 8])

    When "provisioning again"
    error = assert_raises(Dev::WslProvisioner::RestartRequiredError) { prov.provision!(cpus: 12, memory_gib: 24) }

    Then "the file is as it was and the message says the restart is still pending"
    wslconfig == text
    error.message.include?("wsl --shutdown")

    Cleanup
    nil
  end

  test "undersized and idle: ratchets each field to max(current, hint), preserving the rest of the file" do
    Given "a laptop-sized config, no containers"
    text = "[wsl2]\nmemory=8GB\nprocessors=16\nnetworkingMode=mirrored\n"
    prov, _executor = provisioner(config: text, observed: [16, 8], containers: [])

    When "a bigger project provisions"
    error = assert_raises(Dev::WslProvisioner::RestartRequiredError) { prov.provision!(cpus: 12, memory_gib: 24) }

    Then "memory grows, processors keep their larger value, other keys stay, reclaim is added, restart requested"
    wslconfig == "[wsl2]\nmemory=24GB\nprocessors=16\nnetworkingMode=mirrored\n\n[experimental]\nautoMemoryReclaim=gradual\n"
    error.message.include?("16 cpus / 24 GiB")

    Cleanup
    nil
  end

  test "undersized and busy: refuses, naming the containers, and writes nothing" do
    Given "an undersized VM with another project's containers running"
    text = "[wsl2]\nmemory=8GB\nprocessors=4\n"
    prov, _executor = provisioner(config: text, observed: [4, 8], containers: %w[snappy-build unreal-engine-css])

    When "provisioning"
    error = assert_raises(Dev::WslProvisioner::EngineBusyError) { prov.provision!(cpus: 12, memory_gib: 24) }

    Then "the file is untouched and the message lists the containers and the way out"
    wslconfig == text
    error.message.include?("snappy-build")
    error.message.include?("unreal-engine-css")
    error.message.include?("dev reset-container")

    Cleanup
    nil
  end

  test "undersized and busy with force: writes anyway and asks for the restart — the containers' fate is the user's" do
    Given "an undersized VM with containers running"
    text = "[wsl2]\nmemory=8GB\nprocessors=4\n"
    prov, executor = provisioner(config: text, observed: [4, 8], containers: %w[snappy-build])

    When "provisioning with force"
    error = assert_raises(Dev::WslProvisioner::RestartRequiredError) do
      prov.provision!(cpus: 12, memory_gib: 24, force: true)
    end

    Then "the file is ratcheted, docker ps was not even consulted, and the message names the restart"
    wslconfig == "[wsl2]\nmemory=24GB\nprocessors=12\n\n[experimental]\nautoMemoryReclaim=gradual\n"
    executor.runs.none? { |bin, *_rest| bin == "docker" }
    error.message.include?("wsl --shutdown")

    Cleanup
    nil
  end

  test "a hint above the Windows hardware is unsatisfiable: nothing written" do
    Given "a 28-thread / 64 GiB box"
    prov, _executor = provisioner(config: nil, observed: [4, 8], hardware: [28, 64])

    When "a project asks for more than the machine has"
    error = assert_raises(Dev::WslProvisioner::UnsatisfiableHintError) do
      prov.provision!(cpus: cpus, memory_gib: memory_gib)
    end

    Then "no file appears and the message states both sides"
    wslconfig.nil?
    error.message.include?("28 cpus / 64 GiB")
    error.message.include?("engine_resources")

    Cleanup
    nil

    Where
    cpus | memory_gib
    32   | 24
    12   | 96
  end

  test "a configured value already above the hardware is capped when rewritten" do
    Given "a config someone hand-wrote past the machine, with memory to ratchet"
    text = "[wsl2]\nprocessors=64\nmemory=8GB\n"
    prov, _executor = provisioner(config: text, observed: [28, 8], hardware: [28, 64])

    When "provisioning"
    assert_raises(Dev::WslProvisioner::RestartRequiredError) { prov.provision!(cpus: 12, memory_gib: 24) }

    Then "processors come down to the hardware, memory ratchets"
    wslconfig == "[wsl2]\nprocessors=28\nmemory=24GB\n\n[experimental]\nautoMemoryReclaim=gradual\n"

    Cleanup
    nil
  end

  test "interop disabled: one warning naming the file, nothing else" do
    Given "a distro with interop off"
    prov, executor = provisioner(config: nil, observed: [4, 8], interop: false)

    When "provisioning"
    prov.provision!(cpus: 12, memory_gib: 24)

    Then "a warning points at .wslconfig; no Windows binary was called and nothing was written"
    @out.string.include?(".wslconfig")
    @out.string.include?("interop")
    executor.runs.none? { |bin, *_rest| bin.end_with?(".exe") }
    wslconfig.nil?

    Cleanup
    nil
  end

  test "a nil hint is nothing to converge beyond the reclaim default" do
    Given "a project without a resources hint, on a configured box"
    text = "[wsl2]\nmemory=64GB\nprocessors=28\n\n[experimental]\nautoMemoryReclaim=gradual\n"
    prov, _executor = provisioner(config: text, observed: [28, 64])

    When "provisioning"
    prov.provision!

    Then "nothing changes"
    wslconfig == text

    Cleanup
    nil
  end
end
