# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "dev/terminal_owner"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ShellTest < Minitest::Test
  test "run spawns the argv in the directory with the env added and waits for its status" do
    Given
    root = Pathname(Dir.mktmpdir("shell-"))

    When
    status = Dev::Lifecycle::Shell.new.run(["sh", "-c", 'echo "$GREETING" > out.txt; exit 4'], chdir: root, env: { "GREETING" => "hi" })

    Then
    !status.success?
    status.exitstatus == 4
    (root / "out.txt").read == "hi\n"
    Dev::Lifecycle::Shell.describe(status) == "exited 4"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "pipeline chains the stages and reports every stage's status" do
    Given
    root = Pathname(Dir.mktmpdir("shell-"))

    When
    statuses = Dev::Lifecycle::Shell.new.pipeline([["printf", "b\na\n"], ["sort"], ["sh", "-c", "cat > sorted.txt; exit 1"]], chdir: root)

    Then
    statuses.map(&:success?) == [true, true, false]
    (root / "sorted.txt").read == "a\nb\n"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a child inherits the terminal, so under a spinner neither run nor pipeline spawns: refused by the terminal's owner, nothing run (plans#52)" do
    Given
    root = Pathname(Dir.mktmpdir("shell-"))

    When
    run = assert_raises(Dev::TerminalOwner::UnderSpinnerError) do
      Dev::TerminalOwner.spinning { Dev::Lifecycle::Shell.new.run(["sh", "-c", "touch ran"], chdir: root) }
    end
    pipeline = assert_raises(Dev::TerminalOwner::UnderSpinnerError) do
      Dev::TerminalOwner.spinning { Dev::Lifecycle::Shell.new.pipeline([["printf", "x"], ["sh", "-c", "cat > piped"]], chdir: root) }
    end

    Then
    run.message.start_with?("`sh -c touch ran` would take the terminal under a spinner")
    pipeline.message.start_with?("`printf | sh` would take the terminal under a spinner")
    root.children.empty?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "describe names the signal when one ended the child" do
    Given
    status = Dev::Lifecycle::Shell.new.run(["sh", "-c", "kill -TERM $$"], chdir: Pathname(Dir.pwd))

    Expect
    status.signaled?
    Dev::Lifecycle::Shell.describe(status) == "was killed by signal #{Signal.list.fetch("TERM")}"
  end

  test "a missing executable or directory is a SpawnError naming it: #{what}" do
    When
    Dev::Lifecycle::Shell.new.run(argv, chdir: Pathname(chdir))

    Then
    error = raises(Dev::Lifecycle::Shell::SpawnError)
    error.message.include?(named)

    Where
    what          | argv                       | chdir                  | named
    "executable"  | ["no-such-program-xyz"]    | Dir.pwd                | '"no-such-program-xyz"'
    "directory"   | ["true"]                   | "/nonexistent/dir/xyz" | "/nonexistent/dir/xyz"
  end

  test "a missing executable in a pipeline is a SpawnError too" do
    When
    Dev::Lifecycle::Shell.new.pipeline([["true"], ["no-such-program-xyz"]], chdir: Pathname(Dir.pwd))

    Then
    error = raises(Dev::Lifecycle::Shell::SpawnError)
    error.message.include?('"true" | "no-such-program-xyz"')
  end
end
