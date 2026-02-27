# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command_runner"
require "fileutils"
require "tempfile"

transform!(RSpock::AST::Transformation)
class CommandRunnerTest < Minitest::Test
  extend T::Sig
  include SorbetHelper

  def setup
    @ui = typed_mock(Dev::Cli::Ui)
    @runner = Dev::CommandRunner.new(ui: @ui)
  end

  test "run replaces process when not a TTY" do
    Given "a command with pretty_ui true in a non-TTY environment"
    cmd = Dev::Command.new(run: "./bin/test.rb", pretty_ui: true)

    When "we run the command"
    @runner.run(cmd)

    Then "the process is replaced via Kernel.exec"
    1 * Kernel.exec("./bin/test.rb")
    Dir.pwd == Dev::TARGET_PROJECT_ROOT.to_s
  end

  test "run replaces process with args appended" do
    Given "a command with args in a non-TTY environment"
    cmd = Dev::Command.new(run: "./bin/test.rb", pretty_ui: true)

    When "we run the command with extra args"
    @runner.run(cmd, args: ["--verbose", "--seed", "42"])

    Then "the process is replaced with args shell-joined"
    1 * Kernel.exec("./bin/test.rb --verbose --seed 42")
  end

  test "run replaces process when pretty_ui is false even with TTY" do
    Given "a command with pretty_ui false and stdout reports TTY"
    cmd = Dev::Command.new(run: "./bin/console", pretty_ui: false)
    @runner.stubs(:tty?).returns(true)

    When "we run the command"
    @runner.run(cmd)

    Then "the process is replaced via Kernel.exec"
    1 * Kernel.exec("./bin/console")
  end

  test "run spawns subprocess with capture when TTY and pretty_ui" do
    Given "a command that writes to stdout and runner reports TTY"
    tmp = Tempfile.new(["test", ".sh"])
    tmp.write("#!/bin/sh\necho 'subprocess output'")
    tmp.close
    File.chmod(0o755, tmp.path)
    cmd = Dev::Command.new(run: tmp.path, pretty_ui: true)
    @runner.stubs(:tty?).returns(true)
    @ui.expects(:frame).with(tmp.path).once.yields
    @ui.expects(:done).once

    When "we run the command and capture output"
    out, _ = capture_io { @runner.run(cmd) }

    Then "subprocess output was captured and printed"
    assert_includes out, "subprocess output"

    Cleanup
    tmp.unlink
  end

  test "run spawns subprocess with args passed through" do
    Given "a command with args and runner reports TTY"
    tmp = Tempfile.new(["test", ".sh"])
    tmp.write("#!/bin/sh\necho \"args: $@\"")
    tmp.close
    File.chmod(0o755, tmp.path)
    cmd = Dev::Command.new(run: tmp.path, pretty_ui: true)
    expected_shell_command = "#{tmp.path} --verbose"
    @runner.stubs(:tty?).returns(true)
    @ui.expects(:frame).with(expected_shell_command).once.yields
    @ui.expects(:done).once

    When "we run the command with args and capture output"
    out, _ = capture_io { @runner.run(cmd, args: ["--verbose"]) }

    Then "subprocess received the args"
    assert_includes out, "args: --verbose"

    Cleanup
    tmp.unlink
  end

  test "run raises when subprocess fails" do
    Given "a command that exits with non-zero status and runner reports TTY"
    tmp = Tempfile.new(["test", ".sh"])
    tmp.write("#!/bin/sh\nexit 1")
    tmp.close
    File.chmod(0o755, tmp.path)
    cmd = Dev::Command.new(run: tmp.path, pretty_ui: true)
    @runner.stubs(:tty?).returns(true)
    @ui.stubs(:frame).yields

    When "we run the command"
    err = assert_raises(RuntimeError) { @runner.run(cmd) }

    Then "the error message includes the command path"
    assert_includes err.message, tmp.path

    Cleanup
    tmp.unlink
  end
end
