# typed: false
# frozen_string_literal: true

require "fileutils"
require "test_helper"
require "tmpdir"
require "dev/stream"
require "dev/stream_hook"
require "support/recording_ui"

# The hook's command boundary: every system and capture recorded; svc.sh
# and the owner's writes answer as the test says. A `tee` as the owner
# performs the write for real into the dir, so the file is checked.
class RecordingHookExecutor
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
class Dev::StreamHookTest < Minitest::Test
  STREAM = Dev::Stream.parse("d3mlabs/ai-flow@gh ~> 1")

  test "converging a stream records it beside the runner's own env and installs the job-started script; a second converge changes nothing" do
    Given "a runner dir whose .env the runner wrote, no service yet"
    dir = runner_dir
    File.write(File.join(dir, ".env"), "LANG=en_US.UTF-8\n")
    exec = RecordingHookExecutor.new
    ui = RecordingUi.new
    hook = Dev::StreamHook.new(executor: exec, host_platform: "linux-x64", as_user: nil, ui: ui)

    When
    hook.converge!(runner_dir: dir, stream: STREAM)

    Then "the runner's line is kept, ours follow it; the script runs the follow verb for this dir, executable"
    File.read(File.join(dir, ".env")) ==
      "LANG=en_US.UTF-8\nACTIONS_RUNNER_HOOK_JOB_STARTED=#{dir}/dev-job-started.sh\nDEV_STREAM=d3mlabs/ai-flow@gh ~> 1\n"
    script = File.read(File.join(dir, "dev-job-started.sh"))
    script.start_with?("#!/usr/bin/env bash\n")
    script.include?("set -euo pipefail")
    script.include?("exec dev runner follow #{dir.inspect}")
    File.executable?(File.join(dir, "dev-job-started.sh"))
    Dev::StreamHook.recorded(dir) == STREAM
    exec.systems.empty?
    ui.rows == [[:step, "Pointing the job-started hook of #{dir} at d3mlabs/ai-flow@gh ~> 1", 0]]
  end

  test "a dir already following the stream is left alone: nothing said, nothing run, the service not bounced" do
    Given "a dir converged once, with a service"
    dir = runner_dir
    File.write(File.join(dir, ".service"), "unit\n")
    Dev::StreamHook.new(executor: RecordingHookExecutor.new, host_platform: "linux-x64", as_user: nil, ui: RecordingUi.new).converge!(runner_dir: dir, stream: STREAM)
    exec = RecordingHookExecutor.new
    ui = RecordingUi.new

    When "converged again to the same stream"
    Dev::StreamHook.new(executor: exec, host_platform: "linux-x64", as_user: nil, ui: ui).converge!(runner_dir: dir, stream: STREAM)

    Then
    ui.rows.empty?
    exec.systems.empty?
  end

  test "a change on a dir with a service bounces it around the write, in the OS's svc.sh dialect: #{platform}" do
    Given "an enrolled dir with its service record"
    dir = runner_dir
    File.write(File.join(dir, ".service"), "actions.runner.d3mlabs.host-agent.service\n")
    exec = RecordingHookExecutor.new

    When
    Dev::StreamHook.new(executor: exec, host_platform: platform, as_user: nil, ui: RecordingUi.new).converge!(runner_dir: dir, stream: STREAM)

    Then
    exec.systems == [[stop, dir], [start, dir]]

    Where
    platform      | stop                          | start
    "linux-x64"   | ["sudo", "./svc.sh", "stop"]  | ["sudo", "./svc.sh", "start"]
    "osx-arm64"   | ["./svc.sh", "stop"]          | ["./svc.sh", "start"]
  end

  test "a stream of nil removes the hook: our lines leave the env, the script goes, the runner's own lines stay" do
    Given "a dir following the stream"
    dir = runner_dir
    File.write(File.join(dir, ".env"), "LANG=C\n")
    hook = Dev::StreamHook.new(executor: RecordingHookExecutor.new, host_platform: "linux-x64", as_user: nil, ui: RecordingUi.new)
    hook.converge!(runner_dir: dir, stream: STREAM)

    When
    hook.converge!(runner_dir: dir, stream: nil)

    Then
    File.read(File.join(dir, ".env")) == "LANG=C\n"
    !File.exist?(File.join(dir, "dev-job-started.sh"))
    Dev::StreamHook.recorded(dir).nil?
  end

  test "a dir following nothing, asked to follow nothing, is left untouched — no .env is created" do
    Given "a bare dir"
    dir = runner_dir
    ui = RecordingUi.new

    When
    Dev::StreamHook.new(executor: RecordingHookExecutor.new, host_platform: "linux-x64", as_user: nil, ui: ui).converge!(runner_dir: dir, stream: nil)

    Then
    !File.exist?(File.join(dir, ".env"))
    ui.rows.empty?
  end

  test "another user's enrollment is written as that user: tee on stdin, chmod, and rm through sudo" do
    Given "a dir owned by the runner user (as far as the hook knows)"
    dir = runner_dir
    exec = RecordingHookExecutor.new
    hook = Dev::StreamHook.new(executor: exec, host_platform: "linux-x64", as_user: "ai-flow-runner", ui: RecordingUi.new)

    When
    hook.converge!(runner_dir: dir, stream: STREAM)

    Then "each file went through tee as the user, with its content on stdin; modes through chmod as the user"
    exec.captures.map(&:first) == [
      ["sudo", "-u", "ai-flow-runner", "-H", "tee", "#{dir}/.env"],
      ["sudo", "-u", "ai-flow-runner", "-H", "tee", "#{dir}/dev-job-started.sh"],
    ]
    exec.captures.fetch(0).fetch(1) == "ACTIONS_RUNNER_HOOK_JOB_STARTED=#{dir}/dev-job-started.sh\nDEV_STREAM=d3mlabs/ai-flow@gh ~> 1\n"
    exec.systems == [
      [["sudo", "-u", "ai-flow-runner", "-H", "chmod", "0644", "#{dir}/.env"], nil],
      [["sudo", "-u", "ai-flow-runner", "-H", "chmod", "0755", "#{dir}/dev-job-started.sh"], nil],
    ]
  end

  test "another user's hook is removed as that user: rm through sudo, in the dir" do
    Given "a dir following the stream as the runner user"
    dir = runner_dir
    exec = RecordingHookExecutor.new
    hook = Dev::StreamHook.new(executor: exec, host_platform: "linux-x64", as_user: "ai-flow-runner", ui: RecordingUi.new)
    hook.converge!(runner_dir: dir, stream: STREAM)

    When
    hook.converge!(runner_dir: dir, stream: nil)

    Then
    exec.systems.last == [["sudo", "-u", "ai-flow-runner", "-H", "rm", "-f", "dev-job-started.sh"], dir]
    File.read(File.join(dir, ".env")) == ""
  end

  test "a write the owner refuses is WriteError" do
    Given "tee refused"
    dir = runner_dir

    When
    Dev::StreamHook.new(executor: RecordingHookExecutor.new(tee_ok: false), host_platform: "linux-x64", as_user: "ai-flow-runner", ui: RecordingUi.new)
      .converge!(runner_dir: dir, stream: STREAM)

    Then
    error = raises Dev::StreamHook::WriteError
    error.message.include?("tee: permission denied")
  end

  test "svc.sh refusing is ServiceRestartError" do
    Given "an enrolled dir whose svc.sh fails"
    dir = runner_dir
    File.write(File.join(dir, ".service"), "unit\n")

    When
    Dev::StreamHook.new(executor: RecordingHookExecutor.new(svc_ok: false), host_platform: "linux-x64", as_user: nil, ui: RecordingUi.new)
      .converge!(runner_dir: dir, stream: STREAM)

    Then
    error = raises Dev::StreamHook::ServiceRestartError
    error.message.include?("svc.sh stop failed")
  end

  test "recorded reads the stream a dir follows from among the env's other keys, and nothing from a dir without one" do
    Given "three dirs: no .env, an .env with no stream, a stream among other keys"
    bare = runner_dir
    streamless = runner_dir
    File.write(File.join(streamless, ".env"), "LANG=C\n")
    following = runner_dir
    File.write(File.join(following, ".env"), "LANG=C\nDEV_STREAM=d3mlabs/ai-flow@gh ~> 1\nX=1\n")

    Expect
    Dev::StreamHook.recorded(bare).nil?
    Dev::StreamHook.recorded(streamless).nil?
    Dev::StreamHook.recorded(following) == STREAM
  end

  test "a recorded word that is not a stream is refused as malformed, not read as nothing" do
    Given
    dir = runner_dir
    File.write(File.join(dir, ".env"), "DEV_STREAM=ai-flow latest\n")

    When
    Dev::StreamHook.recorded(dir)

    Then "the error names the file and the way out"
    error = raises Dev::Stream::MalformedError
    error.message.include?("#{dir}/.env: DEV_STREAM")
    error.message.include?("dev runner register")
  end

  private

  def runner_dir
    Dir.mktmpdir("actions-runner-agent")
  end
end
