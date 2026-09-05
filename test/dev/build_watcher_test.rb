# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_watcher"
require "fileutils"
require "open3"
require "stringio"
require "tmpdir"

# Dev::BuildWatcher with the OS mechanism (run_once) replaced by a scripted sequence
# of results, so the retry/classify policy is tested without real processes.
class ScriptedWatcher < Dev::BuildWatcher
  attr_reader :calls

  def initialize(results:, **kwargs)
    super(**kwargs)
    @results = results.dup
    @calls = 0
  end

  def run_once(_argv)
    @calls += 1
    @results.shift
  end
end unless defined?(ScriptedWatcher)

transform!(RSpock::AST::Transformation)
class BuildWatcherTest < Minitest::Test
  def watcher(**kwargs)
    Dev::BuildWatcher.new(container_name: "c", out: StringIO.new, stall_after: 300, cpu_floor: 5.0, **kwargs)
  end

  def scripted(results, max_attempts: 5)
    ScriptedWatcher.new(results: results, container_name: "c", out: StringIO.new, max_attempts: max_attempts)
  end

  def result(outcome, output = "")
    Dev::BuildWatcher::Result.new(outcome, output)
  end

  test "stalled? is true only when both silent long enough and idle CPU" do
    Given "a watcher with default thresholds"
    w = watcher

    Expect "silent + idle is a stall; busy CPU or recent output is not"
    w.stalled?(idle_seconds: 400, cpu_percent: 0.0) == true
    w.stalled?(idle_seconds: 400, cpu_percent: 80.0) == false
    w.stalled?(idle_seconds: 10, cpu_percent: 0.0) == false
  end

  test "classify_failure retries on a Rosetta/clang crash signature" do
    Given "output with a crash signature"
    w = watcher

    Expect
    w.classify_failure("rosetta error: failed to open elf") == :retry
    w.classify_failure("clang++: error: unable to spawn process (posix_spawn failed)") == :retry
    w.classify_failure("PLATFORM: Segmentation fault (core dumped)") == :retry
  end

  test "classify_failure fails fast on a genuine compile error" do
    Given "output with only a real compile error"
    w = watcher

    Expect
    w.classify_failure("main.cpp:3:5: error: expected ';'") == :fail
    w.classify_failure("just some unrelated noise") == :fail
  end

  test "run returns true on the first successful attempt" do
    Given "a run that succeeds immediately"
    w = scripted([result(:success)])

    When "running"
    ok = w.run(["docker", "run"])

    Then
    ok == true
    w.calls == 1
  end

  test "run retries a hung build and succeeds on the next attempt" do
    Given "a stall followed by a success"
    w = scripted([result(:stalled, "...building..."), result(:success)])

    When "running"
    ok = w.run(["docker", "run"])

    Then
    ok == true
    w.calls == 2
  end

  test "run retries a transient crash and succeeds" do
    Given "a crash-signature failure followed by a success"
    w = scripted([result(:failed, "rosetta error: boom"), result(:success)])

    When "running"
    ok = w.run(["docker", "run"])

    Then
    ok == true
    w.calls == 2
  end

  test "run fails fast on a genuine compile error without retrying" do
    Given "a failure whose output is a real compile error"
    w = scripted([result(:failed, "main.cpp:3:5: error: nope"), result(:success)])

    When "running"
    ok = w.run(["docker", "run"])

    Then "it stops after the first attempt"
    ok == false
    w.calls == 1
  end

  test "run gives up after the attempt cap on persistent stalls" do
    Given "a build that stalls every attempt"
    w = scripted([result(:stalled), result(:stalled), result(:stalled)], max_attempts: 3)

    When "running"
    ok = w.run(["docker", "run"])

    Then
    ok == false
    w.calls == 3
  end

  test "run_once spawns the command, streams its output, and reports success" do
    Given "a watcher with a fast poll and a name no container holds"
    w = Dev::BuildWatcher.new(container_name: "bw-test-#{Process.pid}", out: StringIO.new, poll: 1)

    When "running a real short-lived process"
    result = w.send(:run_once, ["sh", "-c", "echo built"])

    Then
    result.outcome == :success
    result.output.include?("built") == true
  end

  test "run_once reports a non-zero exit as failed with the captured output" do
    Given "a watcher with a fast poll and a name no container holds"
    w = Dev::BuildWatcher.new(container_name: "bw-test-#{Process.pid}", out: StringIO.new, poll: 1)

    When "running a real process that fails"
    result = w.send(:run_once, ["sh", "-c", "echo boom >&2; exit 3"])

    Then "stderr rides the merged capture"
    result.outcome == :failed
    result.output.include?("boom") == true
  end

  test "wait_or_kill kills a silent idle build and reports the stall" do
    Given "a fake docker (idle stats, successful kill) and a silent long-running process"
    tmpdir = Dir.mktmpdir("bw-fake-docker-")
    fake_docker = File.join(tmpdir, "docker")
    File.write(fake_docker, "#!/bin/sh\ncase \"$1\" in\n  stats) exit 1 ;;\nesac\nexit 0\n")
    FileUtils.chmod(0o755, fake_docker)
    original_path = ENV["PATH"]
    ENV["PATH"] = "#{tmpdir}:#{original_path}"
    io = StringIO.new
    w = Dev::BuildWatcher.new(container_name: "bw-stall-test", out: io, poll: 0)
    stdin, out, wait_thr = Open3.popen2e("sleep", "1")

    When "waiting on the silent process"
    killed = w.send(:wait_or_kill, wait_thr) { 999.0 }

    Then "the stall is detected and the container kill is announced"
    killed == true
    assert_includes io.string, "killing hung container bw-stall-test"

    Cleanup
    ENV["PATH"] = original_path
    stdin.close
    out.close
    wait_thr.join
    FileUtils.rm_rf(tmpdir)
  end

  test "container_cpu parses the docker stats percentage" do
    Given "a fake docker whose stats report 42.5%"
    tmpdir = Dir.mktmpdir("bw-fake-docker-")
    fake_docker = File.join(tmpdir, "docker")
    File.write(fake_docker, "#!/bin/sh\nprintf '42.5%%\\n'\n")
    FileUtils.chmod(0o755, fake_docker)
    original_path = ENV["PATH"]
    ENV["PATH"] = "#{tmpdir}:#{original_path}"
    w = watcher

    Expect "the percentage is parsed as a Float"
    w.send(:container_cpu) == 42.5

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(tmpdir)
  end

  test "container_cpu reports idle when docker cannot be executed at all" do
    Given "a PATH with no docker"
    tmpdir = Dir.mktmpdir("bw-empty-path-")
    original_path = ENV["PATH"]
    ENV["PATH"] = tmpdir
    w = watcher

    Expect "the unreadable value counts as idle"
    w.send(:container_cpu) == 0.0

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(tmpdir)
  end

  test "now returns a monotonic Float for stall timing" do
    Given "a watcher"
    w = watcher

    When "sampling the clock twice"
    first = w.send(:now)
    second = w.send(:now)

    Then
    first.is_a?(Float) == true
    (second >= first) == true
  end
end
