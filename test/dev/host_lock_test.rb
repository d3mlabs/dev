# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/host_lock"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::HostLockTest < Minitest::Test
  # A host-wide mutex on a resource every identity on the box shares (the
  # brew prefix — ai-flow#116, dev#483): two runner slots, or a human and
  # an agent, converging the same missing keg at once must take turns, not
  # trip over brew's own per-formula lock. flock(2) is the mechanism — the
  # kernel releases it when the holder dies, so there is no stale-lock
  # ritual — and the lockfile lives under the data root, which the agent
  # bootstrap already shares between the identities.
  test "synchronize creates the lockfile under <root>/locks and yields the block's value" do
    Given "a lock in an empty root"
    root = Dir.mktmpdir("host-lock-test-")
    lock = Dev::HostLock.new(name: "brew", root: root)

    When
    value = lock.synchronize { :converged }

    Then
    value == :converged
    File.exist?(File.join(root, "locks", "brew.lock"))

    Cleanup
    FileUtils.rm_rf(root)
  end

  # The contention test is two processes, not two threads or a timer: a
  # child asks the kernel, non-blocking, whether the lock is free while the
  # parent holds it and again after the parent let go. Each answer is a
  # fact about the lock's state at that moment, so the test cannot flake.
  test "while held, another process cannot take the lock; once released, it can" do
    Given "a lock held by this process"
    root = Dir.mktmpdir("host-lock-test-")
    lock = Dev::HostLock.new(name: "brew", root: root)
    held, released = nil

    When "a second process probes the lock during and after the hold"
    lock.synchronize do
      held = other_process_can_lock?(lock.path)
    end
    released = other_process_can_lock?(lock.path)

    Then "blocked while held, free afterwards"
    held == false
    released == true

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "synchronize is re-entrant on one instance: a write under a converge under the lock does not deadlock" do
    Given "a lock"
    root = Dir.mktmpdir("host-lock-test-")
    lock = Dev::HostLock.new(name: "brew", root: root)

    When "the block takes the same lock again"
    depth = lock.synchronize { lock.synchronize { lock.synchronize { 3 } } }

    Then "the inner holds are no-ops on the outer one, and the lock is free afterwards"
    depth == 3
    other_process_can_lock?(lock.path) == true

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "the block's exception releases the lock" do
    Given "a lock whose block raises"
    root = Dir.mktmpdir("host-lock-test-")
    lock = Dev::HostLock.new(name: "brew", root: root)
    begin
      lock.synchronize { raise "brew refused" }
    rescue RuntimeError
      nil
    end

    Expect "another process can take it"
    other_process_can_lock?(lock.path) == true

    Cleanup
    FileUtils.rm_rf(root)
  end

  private

  # Whether a fresh process can take the lock right now — a non-blocking
  # flock from a forked child, answered over a pipe. exit! skips the
  # child's at_exit hooks (Minitest's autorun among them).
  #
  # @param path [String] the lockfile
  # @return [Boolean]
  def other_process_can_lock?(path)
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      File.open(path, File::RDONLY) do |file|
        writer.write(file.flock(File::LOCK_EX | File::LOCK_NB) ? "y" : "n")
      end
      writer.close
      exit!(0)
    end
    writer.close
    answer = reader.read
    reader.close
    Process.wait(pid)
    answer == "y"
  end
end
