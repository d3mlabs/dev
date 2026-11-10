# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/engine_resources"
require "dev/privileged_steps"
require "dev/wsl_host"
require "dev/wsl_keepalive_task"
require "dev/wsl_provisioner"
require "dev/wsl_runner_host"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"

# Records every invocation; powershell.exe and sudo are true boundaries. The
# Windows side it describes is what Task Scheduler reports for the keepalive
# (+task+, a JSON record or nil for an interop that prints nothing) and which
# scripts fail when run (+failing+: substrings of the decoded script; the
# elevated wrapper carries its inner script encoded, so it is matched by its
# own text, e.g. "RunAs").
class RecordedRunnerHostExecutor
  attr_reader :runs

  def initialize(task: nil, failing: [])
    @task = task
    @failing = Array(failing)
    @runs = []
  end

  def run(*cmd)
    @runs << cmd
    return true if cmd.first == "sudo"

    script = script_of(cmd)
    @failing.none? { |text| script.include?(text) }
  end

  def capture(*cmd)
    @runs << cmd
    @task.nil? ? "" : "#{JSON.generate(@task)}\r\n"
  end

  # The PowerShell scripts run through interop, decoded, in order.
  def scripts
    @runs.select { |bin, *_rest| bin == "powershell.exe" }.map { |cmd| script_of(cmd) }
  end

  def sudo_runs
    @runs.select { |bin, *_rest| bin == "sudo" }
  end

  private

  def script_of(cmd)
    cmd.fetch(cmd.index("-EncodedCommand") + 1).unpack1("m0").force_encoding("UTF-16LE").encode("UTF-8")
  end
end

transform!(RSpock::AST::Transformation)
class Dev::WslRunnerHostTest < Minitest::Test
  include SorbetHelper

  WSL_KERNEL = "Linux version 6.6.87.2-microsoft-standard-WSL2 (root@...) #1 SMP\n"
  SESSION_ENV = { "WSL_INTEROP" => "/run/WSL/8_interop", "WSL_DISTRO_NAME" => "Ubuntu" }.freeze

  # What Task Scheduler reports once dev has registered the keepalive.
  CONVERGED_TASK = {
    "present" => true, "state" => "Running", "execute" => "conhost.exe",
    "arguments" => "--headless wsl.exe -d Ubuntu -u root -- sleep infinity",
    "triggers" => ["MSFT_TaskLogonTrigger"], "executionTimeLimit" => "PT0S", "multipleInstances" => "IgnoreNew",
  }.freeze

  # The task a per-repo bootstrap script left behind: fire-and-forget, with
  # the default three-day limit (cellbound-3d#280).
  BOOTSTRAP_TASK = CONVERGED_TASK.merge(
    "state" => "Ready", "execute" => "wsl.exe", "arguments" => "-d Ubuntu -u root -- /bin/true",
    "executionTimeLimit" => "PT72H", "multipleInstances" => "Parallel",
  ).freeze

  def setup
    @dir = Dir.mktmpdir("wsl-runner-host-test-")
    @binfmt = File.join(@dir, "binfmt_misc")
    FileUtils.mkdir_p(@binfmt)
    @wsl_conf_path = File.join(@dir, "wsl.conf")
    @systemd_run_dir = File.join(@dir, "run", "systemd", "system")
    @out = StringIO.new
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def host(executor:, wsl: true, interop: true, env: SESSION_ENV)
    proc_version_path = File.join(@dir, "version")
    File.write(proc_version_path, wsl ? WSL_KERNEL : "Linux version 6.8.0-generic (buildd@...) #1 SMP\n")
    File.write(File.join(@binfmt, "WSLInterop"), "enabled\ninterpreter /init\nflags: PF\n") if interop
    Dev::WslHost.new(executor: executor, host_os: "linux", proc_version_path: proc_version_path, binfmt_dir: @binfmt, env: env)
  end

  # @param systemd_conf [Boolean] whether wsl.conf enables systemd
  # @param systemd_active [Boolean] whether systemd is PID 1 (the run dir exists)
  def runner_host(executor:, wsl: typed_mock(Dev::WslProvisioner), interop: true, env: SESSION_ENV,
    systemd_conf: true, systemd_active: true)
    File.write(@wsl_conf_path, "[boot]\nsystemd=true\n") if systemd_conf
    FileUtils.mkdir_p(@systemd_run_dir) if systemd_active
    Dev::WslRunnerHost.new(
      host: host(executor: executor, interop: interop, env: env),
      executor: executor,
      steps: Dev::PrivilegedSteps.new(executor: executor, tty: true),
      wsl: wsl,
      wsl_conf_path: @wsl_conf_path,
      systemd_run_dir: @systemd_run_dir,
      out: @out,
    )
  end

  def ratchet_expecting(cpus: nil, memory_gib: nil)
    wsl = typed_mock(Dev::WslProvisioner)
    wsl.expects(:provision!).with(cpus: cpus, memory_gib: memory_gib).once
    wsl
  end

  test "for_host is nil off WSL: the step does not apply on a Mac or a bare Linux box" do
    Expect
    Dev::WslRunnerHost.for_host(host: host(executor: RecordedRunnerHostExecutor.new, wsl: false)).nil?
  end

  test "for_host on WSL is the runner host for this session's distro" do
    When
    runner = Dev::WslRunnerHost.for_host(host: host(executor: RecordedRunnerHostExecutor.new))

    Then
    runner.is_a?(Dev::WslRunnerHost)
    runner.task.name == "Start-WSL-Ubuntu-Runner"
  end

  test "a converged host: one probe, nothing registered, nothing written, the ratchet still asked" do
    Given
    executor = RecordedRunnerHostExecutor.new(task: CONVERGED_TASK)
    runner = runner_host(executor: executor, wsl: ratchet_expecting)

    When
    runner.converge!

    Then "Task Scheduler was read once and nothing else ran"
    executor.scripts.length == 1
    executor.scripts.first.include?("Get-ScheduledTask")
    executor.sudo_runs.empty?
    @out.string.empty?
  end

  test "the ratchet carries the checkout's engine hint" do
    Given
    executor = RecordedRunnerHostExecutor.new(task: CONVERGED_TASK)
    hint = Dev::EngineResources::Hint.new(cpus: 8, memory_gib: 24)
    runner = runner_host(executor: executor, wsl: ratchet_expecting(cpus: 8, memory_gib: 24))

    When
    runner.converge!(resources: hint)

    Then
    executor.sudo_runs.empty?
  end

  test "no interop: register refuses before touching anything, naming the session shape and where to run it" do
    Given
    executor = RecordedRunnerHostExecutor.new(task: CONVERGED_TASK)
    runner = runner_host(executor: executor, interop: false)

    When
    error = assert_raises(Dev::WslRunnerHost::InteropRequiredError) { runner.converge! }

    Then
    error.message.include?("Ubuntu")
    error.message.include?("Windows Terminal")
    error.message.include?("ssh")
    executor.runs.empty?
  end

  test "no keepalive task: it is registered as the logged-on user and started, no elevation" do
    Given
    executor = RecordedRunnerHostExecutor.new(task: { "present" => false })
    runner = runner_host(executor: executor, wsl: ratchet_expecting)

    When
    runner.converge!

    Then "probe, then the register script — which starts the task itself"
    executor.scripts.length == 2
    executor.scripts.last.include?("Register-ScheduledTask -TaskName 'Start-WSL-Ubuntu-Runner'")
    executor.scripts.last.include?("Start-ScheduledTask -TaskName 'Start-WSL-Ubuntu-Runner'")
    !executor.scripts.last.include?("RunAs")
    @out.string.include?("Registering the logon keepalive task 'Start-WSL-Ubuntu-Runner'")
    @out.string.include?("conhost.exe --headless wsl.exe -d Ubuntu -u root -- sleep infinity")
  end

  test "a bootstrap's task that the unelevated write cannot replace: its shortfalls are said, then one UAC prompt replaces it" do
    Given "the unelevated Register-ScheduledTask refused (an administrator's task file)"
    executor = RecordedRunnerHostExecutor.new(task: BOOTSTRAP_TASK, failing: "Register-ScheduledTask")
    runner = runner_host(executor: executor, wsl: ratchet_expecting)

    When
    runner.converge!

    Then "probe, the unelevated attempt, then the same script under RunAs"
    executor.scripts.length == 3
    executor.scripts[1].include?("Register-ScheduledTask")
    executor.scripts[2].include?("Start-Process -FilePath 'powershell.exe' -Verb RunAs")
    @out.string.include?("action does not hold a session (wsl.exe -d Ubuntu -u root -- /bin/true)")
    @out.string.include?("execution time limit PT72H")
    @out.string.include?("one UAC prompt")
  end

  test "a bootstrap's task that the unelevated write replaces: no elevation" do
    Given
    executor = RecordedRunnerHostExecutor.new(task: BOOTSTRAP_TASK)
    runner = runner_host(executor: executor, wsl: ratchet_expecting)

    When
    runner.converge!

    Then
    executor.scripts.length == 2
    !@out.string.include?("UAC")
  end

  test "no prior task and registration fails: StepFailedError, no elevation attempted (nothing of an administrator's to replace)" do
    Given
    executor = RecordedRunnerHostExecutor.new(task: { "present" => false }, failing: "Register-ScheduledTask")
    runner = runner_host(executor: executor)

    When
    error = assert_raises(Dev::WslRunnerHost::StepFailedError) { runner.converge! }

    Then
    error.message.include?("Start-WSL-Ubuntu-Runner")
    executor.scripts.length == 2
  end

  test "the elevated replacement failing (UAC declined) is a StepFailedError too" do
    Given
    executor = RecordedRunnerHostExecutor.new(task: BOOTSTRAP_TASK, failing: ["Register-ScheduledTask", "RunAs"])
    runner = runner_host(executor: executor)

    When
    error = assert_raises(Dev::WslRunnerHost::StepFailedError) { runner.converge! }

    Then
    error.message.include?("elevated")
  end

  test "a converged task that is not running (after `wsl --shutdown`) is started, not re-registered" do
    Given
    executor = RecordedRunnerHostExecutor.new(task: CONVERGED_TASK.merge("state" => "Ready"))
    runner = runner_host(executor: executor, wsl: ratchet_expecting)

    When
    runner.converge!

    Then
    executor.scripts.length == 2
    executor.scripts.last.include?("Start-ScheduledTask -TaskName 'Start-WSL-Ubuntu-Runner'")
    !executor.scripts.last.include?("Register-ScheduledTask")
    @out.string.include?("Starting the logon keepalive task")
  end

  test "starting the task failing is a StepFailedError naming the task" do
    Given
    executor = RecordedRunnerHostExecutor.new(task: CONVERGED_TASK.merge("state" => "Ready"), failing: "Start-ScheduledTask")
    runner = runner_host(executor: executor)

    When
    error = assert_raises(Dev::WslRunnerHost::StepFailedError) { runner.converge! }

    Then
    error.message.include?("start the keepalive task 'Start-WSL-Ubuntu-Runner'")
  end

  test "interop that prints nothing for the task is InteropError, never read as absence" do
    Given
    executor = RecordedRunnerHostExecutor.new(task: nil)
    runner = runner_host(executor: executor)

    When
    error = assert_raises(Dev::WslHost::InteropError) { runner.converge! }

    Then
    error.message.include?("Start-WSL-Ubuntu-Runner")
    executor.scripts.length == 1
  end

  test "systemd not enabled: wsl.conf is written through one sudo session from a staged copy, the ratchet still runs, then a restart is asked for — keepalive included" do
    Given "a distro whose wsl.conf has only automount, systemd not PID 1"
    File.write(@wsl_conf_path, "[automount]\nenabled=true\n")
    executor = RecordedRunnerHostExecutor.new(task: CONVERGED_TASK)
    runner = runner_host(executor: executor, wsl: ratchet_expecting, systemd_conf: false, systemd_active: false)

    When
    error = assert_raises(Dev::WslRunnerHost::RestartRequiredError) { runner.converge! }

    Then "sudo -v, then install -m 0644 <staged> wsl.conf carrying the merged file"
    executor.sudo_runs.length == 2
    executor.sudo_runs.first == %w[sudo -v]
    executor.sudo_runs.last.values_at(0, 1, 2, 3, 5) == ["sudo", "install", "-m", "0644", @wsl_conf_path]
    File.read(executor.sudo_runs.last[4]) == "[automount]\nenabled=true\n\n[boot]\nsystemd=true\n"
    # The message says what to run, and that the keepalive brings the distro back.
    error.message.include?("systemd was enabled in #{@wsl_conf_path}")
    error.message.include?("wsl --shutdown")
    error.message.include?("dev runner register")
    error.message.include?("Start-ScheduledTask -TaskName 'Start-WSL-Ubuntu-Runner'")
    @out.string.include?("Enabling systemd in #{@wsl_conf_path}")
  end

  test "systemd enabled but not running yet (the restart has not happened): nothing written, a restart asked for" do
    Given
    executor = RecordedRunnerHostExecutor.new(task: CONVERGED_TASK)
    runner = runner_host(executor: executor, wsl: ratchet_expecting, systemd_active: false)

    When
    error = assert_raises(Dev::WslRunnerHost::RestartRequiredError) { runner.converge! }

    Then
    executor.sudo_runs.empty?
    error.message.include?("#{@wsl_conf_path} enables systemd but it is not running")
    error.message.include?("wsl --shutdown")
  end

  test "a `.wslconfig` resize pending is the ratchet's restart, with the keepalive step appended" do
    Given
    executor = RecordedRunnerHostExecutor.new(task: CONVERGED_TASK)
    wsl = typed_mock(Dev::WslProvisioner)
    wsl.expects(:provision!).raises(Dev::WslProvisioner::RestartRequiredError, "memory=24GB is ahead of the VM.")
    runner = runner_host(executor: executor, wsl: wsl)

    When
    error = assert_raises(Dev::WslRunnerHost::RestartRequiredError) { runner.converge! }

    Then
    error.message.start_with?("memory=24GB is ahead of the VM. After the shutdown")
    error.message.include?("Start-ScheduledTask -TaskName 'Start-WSL-Ubuntu-Runner'")
  end

  test "the keepalive is converged before systemd, so the restart systemd asks for brings the distro back under it" do
    Given
    executor = RecordedRunnerHostExecutor.new(task: { "present" => false })
    runner = runner_host(executor: executor, wsl: ratchet_expecting, systemd_conf: false, systemd_active: false)

    When
    assert_raises(Dev::WslRunnerHost::RestartRequiredError) { runner.converge! }

    Then "the register script ran, and the sudo write came after it"
    executor.scripts.length == 2
    executor.runs.index { |cmd| cmd.first == "sudo" } > executor.runs.rindex { |cmd| cmd.first == "powershell.exe" }
  end

  test "status reads every fact and mutates nothing" do
    Given
    executor = RecordedRunnerHostExecutor.new(task: BOOTSTRAP_TASK)
    runner = runner_host(executor: executor, systemd_active: false)

    When
    status = runner.status

    Then
    status.systemd_configured
    !status.systemd_active
    status.interop
    status.keepalive.present
    !status.keepalive.running
    !runner.task.holds_session?(status.keepalive)
    executor.scripts.length == 1
    executor.sudo_runs.empty?
  end

  test "status without interop: the keepalive is unknown, not absent, and PowerShell is never asked" do
    Given
    executor = RecordedRunnerHostExecutor.new(task: CONVERGED_TASK)
    runner = runner_host(executor: executor, interop: false, systemd_conf: false)

    When
    status = runner.status

    Then
    !status.interop
    status.keepalive.nil?
    !status.systemd_configured
    status.systemd_active
    executor.runs.empty?
  end
end
