# typed: false
# frozen_string_literal: true

require "fileutils"
require "test_helper"
require "tmpdir"
require "dev/retired_job_hook"
require "support/recording_ui"

# The migration's command boundary: every system and capture recorded;
# svc.sh and the owner's writes answer as the test says. A `tee` as the
# owner performs the write for real into the dir, so the file is checked.
class RecordingRetiredHookExecutor
  attr_reader :systems, :captures

  def initialize(svc_ok: true, tee_ok: true)
    @svc_ok = svc_ok
    @tee_ok = tee_ok
    @systems = []
    @captures = []
  end

  def system(*argv, chdir: nil)
    @systems << [argv, chdir]
    argv.any? { |word| word.end_with?("svc.sh") } ? @svc_ok : true
  end

  def capture(*argv, chdir: nil, stdin: nil)
    @captures << [argv, stdin]
    return ["", "tee: permission denied", false] unless @tee_ok

    File.write(argv.fetch(-1), stdin)
    ["", "", true]
  end
end

transform!(RSpock::AST::Transformation)
class Dev::RetiredJobHookTest < Minitest::Test
  # The record dev 0.9.x's register left in a slot's dir (dev#658).
  HOOK_ENV_LINES = "ACTIONS_RUNNER_HOOK_JOB_STARTED=%<dir>s/dev-job-started.sh\nDEV_STREAM=d3mlabs/ai-flow@gh ~> 1\n"

  test "a dir from 0.9.x loses the hook: dev's env keys leave, the runner's own lines stay, the script goes, the service is bounced once in the OS's svc.sh dialect: #{platform}" do
    Given "an enrolled slot carrying the hook, with its service"
    dir = hooked_dir(env: "LANG=C\n#{format(HOOK_ENV_LINES, dir: "DIR")}X=1\n")
    File.write(File.join(dir, ".service"), "actions.runner.d3mlabs.host-agent.service\n")
    exec = RecordingRetiredHookExecutor.new
    ui = RecordingUi.new

    When
    Dev::RetiredJobHook.new(executor: exec, host_platform: platform, as_user: nil, ui: ui).remove!(runner_dir: dir)

    Then
    File.read(File.join(dir, ".env")) == "LANG=C\nX=1\n"
    !File.exist?(File.join(dir, "dev-job-started.sh"))
    !Dev::RetiredJobHook.present?(dir)
    exec.systems == [[stop, dir], [start, dir]]
    ui.rows.length == 1
    ui.rows.fetch(0).fetch(0) == :step
    ui.rows.fetch(0).fetch(1).start_with?("Removing the job-started hook of #{dir}")

    Where
    platform      | stop                          | start
    "linux-x64"   | ["sudo", "./svc.sh", "stop"]  | ["sudo", "./svc.sh", "start"]
    "osx-arm64"   | ["./svc.sh", "stop"]          | ["./svc.sh", "start"]
  end

  test "a dir without the hook is left untouched: nothing said, nothing run, no .env created — #{what}" do
    Given
    dir = runner_dir
    File.write(File.join(dir, ".env"), env) if env
    File.write(File.join(dir, ".service"), "unit\n")
    exec = RecordingRetiredHookExecutor.new
    ui = RecordingUi.new

    When
    Dev::RetiredJobHook.new(executor: exec, host_platform: "linux-x64", as_user: nil, ui: ui).remove!(runner_dir: dir)

    Then
    !Dev::RetiredJobHook.present?(dir)
    ui.rows.empty?
    exec.systems.empty?
    env.nil? ? !File.exist?(File.join(dir, ".env")) : File.read(File.join(dir, ".env")) == env

    Where
    what                   | env
    "a bare dir"           | nil
    "the runner's own env" | "LANG=C\n"
  end

  test "present? reads the hook from either env key or the script alone — #{what}" do
    Given
    dir = runner_dir
    File.write(File.join(dir, ".env"), env) if env
    FileUtils.touch(File.join(dir, "dev-job-started.sh")) if script

    Expect
    Dev::RetiredJobHook.present?(dir)

    Where
    what               | env                                                        | script
    "the stream key"   | "LANG=C\nDEV_STREAM=d3mlabs/ai-flow@gh ~> 1\n"             | false
    "the hook key"     | "ACTIONS_RUNNER_HOOK_JOB_STARTED=/x/dev-job-started.sh\n"  | false
    "the script alone" | nil                                                        | true
  end

  test "a dir with no service — register, before svc.sh install — is cleaned without a bounce" do
    Given
    dir = hooked_dir(env: format(HOOK_ENV_LINES, dir: "DIR"))
    exec = RecordingRetiredHookExecutor.new

    When
    Dev::RetiredJobHook.new(executor: exec, host_platform: "linux-x64", as_user: nil, ui: RecordingUi.new).remove!(runner_dir: dir)

    Then "only dev's keys were in .env, so it is left empty; nothing bounced"
    File.read(File.join(dir, ".env")) == ""
    !File.exist?(File.join(dir, "dev-job-started.sh"))
    exec.systems.empty?
  end

  test "another user's enrollment is cleaned as that user: tee on stdin, chmod, and rm through sudo, in the dir" do
    Given
    dir = hooked_dir(env: "LANG=C\n#{format(HOOK_ENV_LINES, dir: "DIR")}")
    exec = RecordingRetiredHookExecutor.new

    When
    Dev::RetiredJobHook.new(executor: exec, host_platform: "linux-x64", as_user: "ci", ui: RecordingUi.new).remove!(runner_dir: dir)

    Then
    exec.captures == [[["sudo", "-u", "ci", "-H", "tee", "#{dir}/.env"], "LANG=C\n"]]
    exec.systems == [
      [["sudo", "-u", "ci", "-H", "chmod", "0644", "#{dir}/.env"], nil],
      [["sudo", "-u", "ci", "-H", "rm", "-f", "dev-job-started.sh"], dir],
    ]
  end

  test "a write the owner refuses is WriteError" do
    Given
    dir = hooked_dir(env: format(HOOK_ENV_LINES, dir: "DIR"))

    When
    Dev::RetiredJobHook.new(executor: RecordingRetiredHookExecutor.new(tee_ok: false), host_platform: "linux-x64", as_user: "ci", ui: RecordingUi.new)
      .remove!(runner_dir: dir)

    Then
    error = raises Dev::RetiredJobHook::WriteError
    error.message.include?("tee: permission denied")
  end

  test "svc.sh refusing is ServiceRestartError" do
    Given
    dir = hooked_dir(env: format(HOOK_ENV_LINES, dir: "DIR"))
    File.write(File.join(dir, ".service"), "unit\n")

    When
    Dev::RetiredJobHook.new(executor: RecordingRetiredHookExecutor.new(svc_ok: false), host_platform: "linux-x64", as_user: nil, ui: RecordingUi.new)
      .remove!(runner_dir: dir)

    Then
    error = raises Dev::RetiredJobHook::ServiceRestartError
    error.message.include?("svc.sh stop failed")
  end

  private

  def runner_dir
    Dir.mktmpdir("retired-hook")
  end

  # A slot's dir as dev 0.9.x left it: the env with the hook's keys
  # (`DIR` standing for the dir), and the script.
  def hooked_dir(env:)
    dir = runner_dir
    File.write(File.join(dir, ".env"), env.gsub("DIR", dir))
    File.write(File.join(dir, "dev-job-started.sh"), "#!/usr/bin/env bash\nexec dev runner follow #{dir.inspect}\n")
    dir
  end
end
