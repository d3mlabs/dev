# typed: false
# frozen_string_literal: true

require "test_helper"
require "build_watcher"
require "stringio"

# BuildWatcher with the OS mechanism (run_once) replaced by a scripted sequence
# of results, so the retry/classify policy is tested without real processes.
class ScriptedWatcher < BuildWatcher
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
    BuildWatcher.new(container_name: "c", out: StringIO.new, stall_after: 300, cpu_floor: 5.0, **kwargs)
  end

  def scripted(results, max_attempts: 5)
    ScriptedWatcher.new(results: results, container_name: "c", out: StringIO.new, max_attempts: max_attempts)
  end

  def result(outcome, output = "")
    BuildWatcher::Result.new(outcome, output)
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
end
