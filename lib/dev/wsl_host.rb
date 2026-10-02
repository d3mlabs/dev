# typed: strict
# frozen_string_literal: true

require "pathname"

require "dev/deps"
require "dev/engine_resources"
require "dev/process_executor"
require "dev/wsl_config"

module Dev
  # Facts about the WSL2 machine dev is running inside, gathered through
  # interop (the Windows binaries WSL exposes on PATH) and the VM's own
  # /proc. On WSL the engine VM is not something dev starts — dev *is inside
  # it* — so this is the read side (am I on WSL, what did the user configure,
  # what did the VM actually get, how big is the box) plus the one write dev
  # makes: `%USERPROFILE%\.wslconfig`. Everything is injectable so tests run
  # on a Mac against fixture files.
  class WslHost
    extend T::Sig

    # A Windows-side probe (cmd.exe, powershell.exe, wslpath) answered nothing
    # usable — interop is off or broken.
    class InteropError < RuntimeError; end

    # The WSL side of `dev engine status`: what the user configured, what the
    # VM got, what the box could give. Configured and hardware are unknown
    # (nil) when interop is off.
    class Status < T::Struct
      extend T::Sig

      const :interop, T::Boolean
      const :configured_cpus, T.nilable(Integer)
      const :configured_memory_gib, T.nilable(Integer)
      const :observed, EngineResources
      const :hardware, T.nilable(EngineResources)

      # Whether `.wslconfig` asks for more than the VM is running — a resize
      # that was written but not applied by `wsl --shutdown` yet. A configured
      # value *below* the observed one (a pending shrink) is not dev's concern.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def restart_pending?
        !WslHost.runs_at_least?(observed, cpus: configured_cpus, memory_gib: configured_memory_gib)
      end
    end

    # The share of configured memory the guest kernel may keep for itself
    # before dev reads the VM as smaller than configured. A `memory=64GB` VM
    # reports ~63 GiB (more than colima's guest keeps, so rounding up to the
    # GiB does not absorb it); comparing exactly would ask for a restart
    # that can never satisfy it.
    MEMORY_SLACK = 0.05

    class << self
      extend T::Sig

      # Whether the VM observably runs at least the given size, allowing for
      # the guest kernel's share of memory. Nil fields require nothing.
      #
      # @param observed [EngineResources] what the VM runs
      # @param cpus [Integer, nil]
      # @param memory_gib [Integer, nil]
      # @return [Boolean]
      sig { params(observed: EngineResources, cpus: T.nilable(Integer), memory_gib: T.nilable(Integer)).returns(T::Boolean) }
      def runs_at_least?(observed, cpus:, memory_gib:)
        cpus_ok = cpus.nil? || observed.cpus >= cpus
        memory_ok = memory_gib.nil? || observed.memory_gib >= memory_gib - memory_slack_gib(memory_gib)
        cpus_ok && memory_ok
      end

      # @param memory_gib [Integer] a configured or requested size
      # @return [Integer] how far below it the VM may report, at least 1 GiB
      sig { params(memory_gib: Integer).returns(Integer) }
      def memory_slack_gib(memory_gib)
        [(memory_gib * MEMORY_SLACK).ceil, 1].max
      end
    end

    PROC_VERSION = "/proc/version"
    BINFMT_DIR = "/proc/sys/fs/binfmt_misc"
    MEMINFO = "/proc/meminfo"
    WSLCONFIG = ".wslconfig"

    USERPROFILE_PROBE = T.let(["cmd.exe", "/c", "echo %USERPROFILE%"].freeze, T::Array[String])
    HARDWARE_PROBE = T.let(
      [
        "powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
        "$cs = Get-CimInstance Win32_ComputerSystem; \"$($cs.NumberOfLogicalProcessors) $($cs.TotalPhysicalMemory)\"",
      ].freeze,
      T::Array[String],
    )

    # @param executor [#run, #quiet?, #capture] process seam for the interop binaries and `nproc`
    # @param host_os [String] "darwin" / "linux" / "windows"
    # @param proc_version_path [String] kernel banner; "microsoft" in it means WSL
    # @param binfmt_dir [String] where WSL registers its interop handler
    # @param meminfo_path [String] the VM's /proc/meminfo
    sig do
      params(
        executor: T.untyped,
        host_os: String,
        proc_version_path: String,
        binfmt_dir: String,
        meminfo_path: String,
      ).void
    end
    def initialize(executor: ProcessExecutor.new, host_os: Dev::Deps.detect_host, proc_version_path: PROC_VERSION,
      binfmt_dir: BINFMT_DIR, meminfo_path: MEMINFO)
      @executor = executor
      @host_os = host_os
      @proc_version_path = proc_version_path
      @binfmt_dir = binfmt_dir
      @meminfo_path = meminfo_path
    end

    # Whether this Linux is a WSL2 distro.
    #
    # @return [Boolean]
    sig { returns(T::Boolean) }
    def wsl?
      return false unless @host_os == "linux"
      return false unless File.exist?(@proc_version_path)

      File.read(@proc_version_path).match?(/microsoft/i)
    end

    # Whether Windows binaries can be run from inside the distro (the
    # `WSLInterop` binfmt handler is registered and enabled).
    #
    # @return [Boolean]
    sig { returns(T::Boolean) }
    def interop?
      Dir.glob(File.join(@binfmt_dir, "WSLInterop*")).any? do |path|
        File.read(path).lines.first.to_s.strip == "enabled"
      end
    end

    # The Windows user's profile directory, as a Linux path (`/mnt/c/Users/<name>`).
    #
    # @return [Pathname]
    # @raise [InteropError] when cmd.exe or wslpath answer nothing
    sig { returns(Pathname) }
    def windows_profile
      windows_path = T.unsafe(@executor).capture(*USERPROFILE_PROBE).strip
      raise InteropError, "`cmd.exe /c echo %USERPROFILE%` printed nothing — is WSL interop enabled?" if windows_path.empty?

      linux_path = T.unsafe(@executor).capture("wslpath", "-u", windows_path).strip
      raise InteropError, "`wslpath -u #{windows_path}` printed nothing" if linux_path.empty?

      Pathname.new(linux_path)
    end

    # @return [Pathname] `%USERPROFILE%\.wslconfig`, as a Linux path
    # @raise [InteropError]
    sig { returns(Pathname) }
    def wslconfig_path
      windows_profile / WSLCONFIG
    end

    # @return [WslConfig] the user's `.wslconfig`, empty when the file does not exist
    # @raise [InteropError]
    # @raise [WslConfig::MalformedValueError]
    sig { returns(WslConfig) }
    def config
      path = wslconfig_path
      WslConfig.parse(path.exist? ? path.read : "")
    end

    # @param config [WslConfig]
    # @return [void]
    # @raise [InteropError]
    sig { params(config: WslConfig).void }
    def write_config(config)
      wslconfig_path.write(config.render)
    end

    # The Windows machine's hardware — the ceiling any `.wslconfig` size must
    # stay under.
    #
    # @return [EngineResources] logical processors and physical RAM
    # @raise [InteropError] when powershell answers nothing parseable
    sig { returns(EngineResources) }
    def hardware
      output = T.unsafe(@executor).capture(*HARDWARE_PROBE).strip
      match = /\A(\d+)\s+(\d+)\z/.match(output)
      if match.nil?
        raise InteropError,
          "could not read the Windows machine's hardware through powershell.exe (got #{output.inspect})"
      end

      EngineResources.from_bytes(cpus: Integer(T.must(match[1])), memory_bytes: Integer(T.must(match[2])))
    end

    # What the VM actually has right now — the size the last `.wslconfig`
    # that was applied gave it, or WSL's defaults.
    #
    # @return [EngineResources]
    sig { returns(EngineResources) }
    def observed
      cpus = Integer(T.unsafe(@executor).capture("nproc").strip)
      kib = File.read(@meminfo_path)[/^MemTotal:\s+(\d+)\s+kB/, 1]
      EngineResources.from_bytes(cpus: cpus, memory_bytes: Integer(T.must(kib)) * 1024)
    end

    # Everything `dev engine status` shows for the WSL side. With interop off
    # only the VM's own facts are available.
    #
    # @return [Status]
    # @raise [WslConfig::MalformedValueError]
    sig { returns(Status) }
    def status
      unless interop?
        return Status.new(interop: false, configured_cpus: nil, configured_memory_gib: nil, observed: observed,
          hardware: nil)
      end

      configured = config
      Status.new(
        interop: true,
        configured_cpus: configured.processors,
        configured_memory_gib: configured.memory_gib,
        observed: observed,
        hardware: hardware,
      )
    end
  end
end
