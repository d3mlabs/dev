# typed: false
# frozen_string_literal: true

# Records every invocation the WSL side makes; cmd.exe / powershell.exe /
# wslpath / nproc / docker are true boundaries. The machine it describes is a
# Windows profile directory, a hardware line, the VM's cpu count, and the
# containers the local daemon is running.
class RecordedWslExecutor
  attr_reader :runs

  # @param userprofile [String, nil] what `cmd.exe /c echo %USERPROFILE%` prints (nil: interop broken, prints nothing)
  # @param profile_dir [String] what `wslpath -u` maps that Windows path to
  # @param hardware [String] what the powershell probe prints: "<logical cpus> <ram bytes>"
  # @param nproc [String] what `nproc` prints
  # @param containers [Array<String>] names `docker ps` reports
  # @param run_ok [Boolean] whether streamed commands (`run`) succeed
  def initialize(userprofile: "C:\\Users\\jpduc", profile_dir: "/mnt/c/Users/jpduc", hardware: "28 68719476736",
    nproc: "28", containers: [], run_ok: true)
    @userprofile = userprofile
    @profile_dir = profile_dir
    @hardware = hardware
    @nproc = nproc
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
    when ["docker", "ps", "--format", "{{.Names}}"]
      @containers.map { |name| "#{name}\n" }.join
    else
      cmd.first == "powershell.exe" ? "#{@hardware}\r\n" : ""
    end
  end
end
