# typed: false
# frozen_string_literal: true

# Records every invocation the WSL side makes; cmd.exe / powershell.exe /
# wslpath / nproc / dmesg / docker are true boundaries. The machine it
# describes is a Windows profile directory, a hardware line, the VM's cpu
# count, the memory Hyper-V announced to the VM, and the containers the local
# daemon is running.
class RecordedWslExecutor
  attr_reader :runs

  # The kernel log of a real WSL2 VM (the gamebox, `memory=64GB`), cut to the
  # lines around hv_balloon's announcement. `%d` is the MB figure.
  DMESG_TEMPLATE = <<~LOG
    [    0.000000] Linux version 6.18.33.1-1 (root@...) (gcc ...) #1 SMP PREEMPT_DYNAMIC
    [    0.000000] BIOS-e820: [mem 0x0000000100000000-0x00000009ffdfffff] usable
    [    0.397090] hv_vmbus: registering driver hv_balloon
    [    0.397949] hv_balloon: Using Dynamic Memory protocol version 2.0
    [    0.398980] hv_balloon: Cold memory discard hint enabled with order 9
    [   48.486745] hv_balloon: Max. dynamic memory size: %d MB
    [   49.102311] hv_netvsc 4de0f36a-7e48-491e-b2b0-e98abcd8c5c1 eth0: VF slot 1 added
  LOG

  # @param userprofile [String, nil] what `cmd.exe /c echo %USERPROFILE%` prints (nil: interop broken, prints nothing)
  # @param profile_dir [String] what `wslpath -u` maps that Windows path to
  # @param hardware [String] what the powershell probe prints: "<logical cpus> <ram bytes>"
  # @param nproc [String] what `nproc` prints
  # @param memory_mb [Integer] the VM's memory as Hyper-V announced it to hv_balloon
  # @param dmesg [String, nil] the whole kernel log `dmesg` prints; default: a real one carrying +memory_mb+
  # @param containers [Array<String>] names `docker ps` reports
  # @param run_ok [Boolean] whether streamed commands (`run`) succeed
  def initialize(userprofile: "C:\\Users\\jpduc", profile_dir: "/mnt/c/Users/jpduc", hardware: "28 68719476736",
    nproc: "28", memory_mb: 65_536, dmesg: nil, containers: [], run_ok: true)
    @userprofile = userprofile
    @profile_dir = profile_dir
    @hardware = hardware
    @nproc = nproc
    @dmesg = dmesg || format(DMESG_TEMPLATE, memory_mb)
    @containers = containers
    @run_ok = run_ok
    @runs = []
  end

  def run(*cmd)
    @runs << cmd
    @run_ok
  end

  def quiet?(*cmd)
    @runs << cmd
    true
  end

  def capture(*cmd)
    @runs << cmd
    case cmd
    when ["cmd.exe", "/c", "echo %USERPROFILE%"]
      @userprofile ? "#{@userprofile}\r\n" : ""
    when ["wslpath", "-u", @userprofile]
      "#{@profile_dir}\n"
    when ["nproc"]
      "#{@nproc}\n"
    when ["dmesg"]
      @dmesg
    when ["docker", "ps", "--format", "{{.Names}}"]
      @containers.map { |name| "#{name}\n" }.join
    else
      cmd.first == "powershell.exe" ? "#{@hardware}\r\n" : ""
    end
  end
end
