# typed: false
# frozen_string_literal: true

require "test_helper"
require "support/recorded_wsl_executor"
require "dev/wsl_host"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class Dev::WslHostTest < Minitest::Test
  WSL_KERNEL = "Linux version 6.6.87.2-microsoft-standard-WSL2 (root@...) (gcc ...) #1 SMP PREEMPT_DYNAMIC\n"
  BARE_KERNEL = "Linux version 6.8.0-45-generic (buildd@lcy02-amd64-115) (x86_64-linux-gnu-gcc-13 ...) #45-Ubuntu SMP\n"

  def setup
    @dir = Dir.mktmpdir("wsl-host-test-")
    @binfmt = File.join(@dir, "binfmt_misc")
    FileUtils.mkdir_p(@binfmt)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # Build a host over the temp fixtures. Fixture files are only written when
  # given, so "absent" is a real missing file.
  def host(executor: RecordedWslExecutor.new, host_os: "linux", proc_version: WSL_KERNEL, interop: "enabled",
    meminfo: "MemTotal:       65890048 kB\nMemFree:        60000000 kB\n")
    proc_version_path = File.join(@dir, "version")
    File.write(proc_version_path, proc_version) if proc_version
    File.write(File.join(@binfmt, "WSLInterop"), "#{interop}\ninterpreter /init\nflags: PF\n") if interop
    meminfo_path = File.join(@dir, "meminfo")
    File.write(meminfo_path, meminfo) if meminfo
    Dev::WslHost.new(
      executor: executor, host_os: host_os, proc_version_path: proc_version_path,
      binfmt_dir: @binfmt, meminfo_path: meminfo_path,
    )
  end

  test "wsl? is the Microsoft kernel on a linux host" do
    Expect
    host(host_os: host_os, proc_version: proc_version).wsl? == wsl

    Where
    host_os  | proc_version | wsl
    "linux"  | WSL_KERNEL   | true
    "linux"  | BARE_KERNEL  | false
    "linux"  | nil          | false
    "darwin" | WSL_KERNEL   | false
  end

  test "interop? reads the binfmt registration" do
    Expect
    host(interop: interop).interop? == enabled

    Where
    interop    | enabled
    "enabled"  | true
    "disabled" | false
    nil        | false
  end

  test "windows_profile asks cmd.exe and converts through wslpath" do
    Given "a host with working interop"
    executor = RecordedWslExecutor.new(userprofile: "C:\\Users\\jpduc", profile_dir: "/mnt/c/Users/jpduc")
    wsl = host(executor: executor)

    Expect "the Linux-side profile path, and .wslconfig under it"
    wsl.windows_profile == Pathname.new("/mnt/c/Users/jpduc")
    wsl.wslconfig_path == Pathname.new("/mnt/c/Users/jpduc/.wslconfig")
    executor.runs.include?(["cmd.exe", "/c", "echo %USERPROFILE%"])
    executor.runs.include?(["wslpath", "-u", "C:\\Users\\jpduc"])
  end

  test "windows_profile raises InteropError when cmd.exe answers nothing" do
    Given "interop that produces no output"
    wsl = host(executor: RecordedWslExecutor.new(userprofile: nil))

    When "asking for the profile"
    error = assert_raises(Dev::WslHost::InteropError) { wsl.windows_profile }

    Then "the message names the probe"
    error.message.include?("USERPROFILE")

    Cleanup
    nil
  end

  test "config reads .wslconfig from the Windows profile and write_config writes it back" do
    Given "a profile directory with a .wslconfig"
    profile = File.join(@dir, "profile")
    FileUtils.mkdir_p(profile)
    File.write(File.join(profile, ".wslconfig"), "[wsl2]\nmemory=8GB\nnetworkingMode=mirrored\n")
    wsl = host(executor: RecordedWslExecutor.new(profile_dir: profile))

    When "reading, ratcheting, and writing"
    config = wsl.config
    wsl.write_config(config.with(memory_gib: 16, processors: 8))

    Then "the read saw the file and the write preserved the unrelated key"
    config.memory_gib == 8
    File.read(File.join(profile, ".wslconfig")) == "[wsl2]\nmemory=16GB\nnetworkingMode=mirrored\nprocessors=8\n"

    Cleanup
    nil
  end

  test "config is empty when .wslconfig does not exist yet" do
    Given "a profile directory without the file"
    profile = File.join(@dir, "profile")
    FileUtils.mkdir_p(profile)
    wsl = host(executor: RecordedWslExecutor.new(profile_dir: profile))

    When "reading, then writing a first config"
    config = wsl.config
    wsl.write_config(config.with(processors: 8, memory_gib: 16, auto_memory_reclaim: "gradual"))

    Then "the read saw nothing and the write created the file"
    config.memory_gib.nil?
    config.processors.nil?
    File.read(File.join(profile, ".wslconfig")) ==
      "[wsl2]\nprocessors=8\nmemory=16GB\n\n[experimental]\nautoMemoryReclaim=gradual\n"

    Cleanup
    nil
  end

  test "hardware reads the Windows machine's logical cpus and RAM through powershell" do
    Given "a 28-thread, 64 GiB gamebox"
    wsl = host(executor: RecordedWslExecutor.new(hardware: "28 68719476736"))

    Expect
    wsl.hardware == Dev::EngineResources.new(cpus: 28, memory_gib: 64)
  end

  test "hardware raises InteropError when powershell does not answer" do
    Given "powershell output dev cannot read"
    wsl = host(executor: RecordedWslExecutor.new(hardware: output))

    When "asking for the hardware"
    error = assert_raises(Dev::WslHost::InteropError) { wsl.hardware }

    Then "the message quotes what came back"
    error.message.include?(output.inspect)

    Cleanup
    nil

    Where
    output          | _
    ""              | nil
    "not a number"  | nil
  end

  test "status gathers configured, observed, and hardware, and knows when a written resize is unapplied" do
    Given "a profile with a .wslconfig and a VM at some size"
    profile = File.join(@dir, "profile")
    FileUtils.mkdir_p(profile)
    File.write(File.join(profile, ".wslconfig"), config)
    cpus, memory_gib = observed
    executor = RecordedWslExecutor.new(profile_dir: profile, nproc: cpus.to_s, hardware: "28 68719476736")
    wsl = host(executor: executor, meminfo: "MemTotal:       #{memory_gib * 1024 * 1024} kB\n")

    When "asking for status"
    status = wsl.status

    Then "every fact is there and restart_pending? reads the gap between configured and observed, " \
         "allowing for the memory the guest kernel keeps (the gamebox: 64 GB configured, 63 GiB observed)"
    status.interop == true
    status.configured_cpus.eql?(configured_cpus)
    status.configured_memory_gib.eql?(configured_memory_gib)
    status.observed == Dev::EngineResources.new(cpus: cpus, memory_gib: memory_gib)
    status.hardware == Dev::EngineResources.new(cpus: 28, memory_gib: 64)
    status.restart_pending? == pending

    Cleanup
    nil

    Where
    config                                 | observed | configured_cpus | configured_memory_gib | pending
    "[wsl2]\nprocessors=28\nmemory=64GB\n" | [28, 64] | 28              | 64                    | false
    "[wsl2]\nprocessors=28\nmemory=64GB\n" | [28, 63] | 28              | 64                    | false
    "[wsl2]\nprocessors=28\nmemory=64GB\n" | [28, 59] | 28              | 64                    | true
    "[wsl2]\nprocessors=28\nmemory=64GB\n" | [27, 64] | 28              | 64                    | true
    "[wsl2]\nprocessors=12\nmemory=24GB\n" | [4, 8]   | 12              | 24                    | true
    "[wsl2]\nmemory=24GB\n"                | [28, 8]  | nil             | 24                    | true
    "[wsl2]\nprocessors=8\nmemory=16GB\n"  | [28, 64] | 8               | 16                    | false
    "[wsl2]\nnetworkingMode=mirrored\n"    | [4, 8]   | nil             | nil                   | false
  end

  test "status with interop off reports only what the VM itself can tell" do
    Given "a distro with interop disabled"
    executor = RecordedWslExecutor.new(nproc: "4")
    wsl = host(executor: executor, interop: "disabled", meminfo: "MemTotal:       8388608 kB\n")

    When "asking for status"
    status = wsl.status

    Then "no Windows binary is called; configured and hardware are unknown; nothing is pending"
    status.interop == false
    status.configured_cpus.nil?
    status.configured_memory_gib.nil?
    status.hardware.nil?
    status.observed == Dev::EngineResources.new(cpus: 4, memory_gib: 8)
    status.restart_pending? == false
    executor.runs.none? { |bin, *_rest| bin.end_with?(".exe") }

    Cleanup
    nil
  end

  test "observed is the VM's own nproc and MemTotal, rounded up like any engine" do
    Given "a VM that reports 28 cpus and 65890048 kB (62.8 GiB)"
    wsl = host(executor: RecordedWslExecutor.new(nproc: "28"), meminfo: "MemTotal:       65890048 kB\n")

    Expect
    wsl.observed == Dev::EngineResources.new(cpus: 28, memory_gib: 63)
  end
end
