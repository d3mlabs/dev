# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/wsl_keepalive_task"
require "json"

transform!(RSpock::AST::Transformation)
class Dev::WslKeepaliveTaskTest < Minitest::Test
  # What Task Scheduler reports for the task dev registers, as the probe
  # script prints it.
  CONVERGED = {
    "present" => true, "state" => "Running", "execute" => "conhost.exe",
    "arguments" => "--headless wsl.exe -d Ubuntu -u root -- sleep infinity",
    "triggers" => ["MSFT_TaskLogonTrigger"], "executionTimeLimit" => "PT0S", "multipleInstances" => "IgnoreNew",
  }.freeze

  def task(distro: "Ubuntu")
    Dev::WslKeepaliveTask.new(distro: distro)
  end

  def observed(**overrides)
    Dev::WslKeepaliveTask.parse_observed(JSON.generate(CONVERGED.merge(overrides.transform_keys(&:to_s))))
  end

  test "the task is named as the per-repo bootstrap scripts named it, so an existing one is replaced in place" do
    Expect
    task.name == "Start-WSL-Ubuntu-Runner"
    task(distro: "Ubuntu-24.04").name == "Start-WSL-Ubuntu-24.04-Runner"
  end

  test "the action holds a client session: a headless conhost running wsl.exe as root with sleep infinity — never a fire-and-forget command" do
    Expect
    task.command == "conhost.exe --headless wsl.exe -d Ubuntu -u root -- sleep infinity"
    task(distro: "Debian").arguments == "--headless wsl.exe -d Debian -u root -- sleep infinity"
  end

  test "parse_observed reads the probe's record: present, running, action, trigger, and the two settings" do
    When
    record = observed

    Then
    record.present
    record.running
    record.execute == "conhost.exe"
    record.arguments == "--headless wsl.exe -d Ubuntu -u root -- sleep infinity"
    record.at_logon
    record.execution_time_limit == "PT0S"
    record.multiple_instances == "IgnoreNew"
  end

  test "parse_observed reads `present: false` as the absent task, and a one-trigger answer however PowerShell shaped it" do
    Expect
    Dev::WslKeepaliveTask.parse_observed('{"present":false}') == Dev::WslKeepaliveTask::Observed::ABSENT
    observed(triggers: "MSFT_TaskLogonTrigger").at_logon
    !observed(triggers: ["MSFT_TaskBootTrigger"]).at_logon
    !observed(state: "Ready").running
  end

  test "parse_observed raises MalformedTaskError on anything but a task record" do
    Given
    error = assert_raises(Dev::WslKeepaliveTask::MalformedTaskError) { Dev::WslKeepaliveTask.parse_observed(answer) }

    Expect "the message quotes what came back"
    error.message.include?(answer.strip.inspect)
    error.message.include?("not a task record")

    Where
    answer                 | _
    "not json"             | nil
    "[1, 2]"               | nil
    '{"present":true}'     | nil
  end

  test "holds_session? is the exact action — execute case-insensitively, the arguments to the letter" do
    Expect
    task.holds_session?(observed(execute: execute, arguments: arguments)) == holds

    Where
    execute       | arguments                                                 | holds
    "conhost.exe" | "--headless wsl.exe -d Ubuntu -u root -- sleep infinity"  | true
    "CONHOST.EXE" | "--headless wsl.exe -d Ubuntu -u root -- sleep infinity"  | true
    "conhost.exe" | "--headless wsl.exe -d Ubuntu -u root -- /bin/true"       | false
    "wsl.exe"     | "-d Ubuntu -u root -- sleep infinity"                     | false
    "conhost.exe" | "--headless wsl.exe -d Debian -u root -- sleep infinity"  | false
  end

  test "holds_session? is false for the absent task" do
    Expect
    !task.holds_session?(Dev::WslKeepaliveTask::Observed::ABSENT)
  end

  test "converged? needs every fact the keepalive depends on, and shortfalls names each one missing" do
    Given
    record = observed(**overrides)

    Expect
    task.converged?(record) == converged
    task.shortfalls(record).length == missing

    Where
    overrides                                                   | converged | missing
    {}                                                          | true      | 0
    { state: "Ready" }                                          | true      | 0
    { arguments: "--headless wsl.exe -d Ubuntu -u root -- /bin/true" } | false | 1
    { triggers: ["MSFT_TaskBootTrigger"] }                      | false     | 1
    { executionTimeLimit: "PT72H" }                             | false     | 1
    { multipleInstances: "Parallel" }                           | false     | 1
    { executionTimeLimit: "PT72H", multipleInstances: "Queue" } | false     | 2
  end

  test "shortfalls say what is wrong in the operator's words" do
    Expect
    task.shortfalls(Dev::WslKeepaliveTask::Observed::ABSENT) == ["no task named 'Start-WSL-Ubuntu-Runner'"]
    task.shortfalls(observed(executionTimeLimit: "PT72H")) == ["execution time limit PT72H (the held session would be killed)"]
    task.shortfalls(observed(arguments: "-d Ubuntu")) == ["action does not hold a session (conhost.exe -d Ubuntu)"]
  end

  test "the probe script reads the task by name and prints one JSON record, `present: false` for none — so an empty answer is interop failing, never absence" do
    Given
    script = task.probe_script

    Expect
    script.include?("Get-ScheduledTask -TaskName 'Start-WSL-Ubuntu-Runner' -ErrorAction SilentlyContinue")
    script.include?(%q(if ($null -eq $task) { '{"present":false}'; exit 0 }))
    script.include?("ConvertTo-Json -Compress")
    %w[present state execute arguments triggers executionTimeLimit multipleInstances].all? { |key| script.include?("#{key} = ") }
  end

  test "the register script is the bootstrap's task, settings included, as the logged-on user — and starts it so the session is held now" do
    Given
    script = task.register_script

    Expect
    script.include?("New-ScheduledTaskAction -Execute 'conhost.exe' -Argument '--headless wsl.exe -d Ubuntu -u root -- sleep infinity'")
    script.include?("New-ScheduledTaskTrigger -AtLogOn")
    script.include?("-ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew")
    script.include?("-AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable")
    script.include?(%q(New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited))
    script.include?("Register-ScheduledTask -TaskName 'Start-WSL-Ubuntu-Runner'")
    script.include?("-Force -ErrorAction Stop")
    script.include?("Start-ScheduledTask -TaskName 'Start-WSL-Ubuntu-Runner' -ErrorAction Stop")
  end

  test "the start script starts the task by name" do
    Expect
    task.start_script.include?("Start-ScheduledTask -TaskName 'Start-WSL-Ubuntu-Runner' -ErrorAction Stop")
  end

  test "elevated wraps a script in one UAC-prompting PowerShell carrying it encoded, and exits with the inner exit code" do
    Given
    inner = task.register_script
    encoded = [inner.encode("UTF-16LE")].pack("m0")

    When
    script = task.elevated(inner)

    Then
    script.include?("Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', '#{encoded}')")
    script.include?("exit $process.ExitCode")
  end

  test "quote makes a single-quoted PowerShell literal, doubling the one character it must" do
    Expect
    Dev::WslKeepaliveTask.quote(value) == quoted

    Where
    value          | quoted
    "Ubuntu"       | "'Ubuntu'"
    "it's"         | "'it''s'"
    "$env:HOME"    | "'$env:HOME'"
  end
end
