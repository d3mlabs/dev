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
    @runner = Dev::CommandRunner.new(ui: @ui, ruby_version: "4.0.1")
    @runner.stubs(:ensure_shadowenv_provisioned!)
  end

  test "run replaces process when repl" do
    Given "a repl command"
    cmd = Dev::Command.new(run: "./bin/console", repl: true)

    When "we run the command"
    @runner.run(cmd)

    Then "the process is replaced via shadowenv exec"
    1 * Kernel.exec({"GEM_HOME" => nil}, "shadowenv", "exec", "--", "sh", "-c", "./bin/console")
  end

  test "run replaces process with args when repl" do
    Given "a repl command with args"
    cmd = Dev::Command.new(run: "./bin/console", repl: true)

    When "we run the command with extra args"
    @runner.run(cmd, args: ["--verbose"])

    Then "the process is replaced with args shell-joined"
    1 * Kernel.exec({"GEM_HOME" => nil}, "shadowenv", "exec", "--", "sh", "-c", "./bin/console --verbose")
  end

  test "run spawns subprocess for non-repl command" do
    Given "a non-repl command that writes to stdout"
    tmp = Tempfile.new(["test", ".sh"])
    tmp.write("#!/bin/sh\necho 'subprocess output'")
    tmp.close
    File.chmod(0o755, tmp.path)
    cmd = Dev::Command.new(run: tmp.path, repl: false)
    @ui.stubs(:print_line)
    @ui.stubs(:done)

    When "we run the command"
    @runner.run(cmd)

    Then "print_line is called for the command header and subprocess output"
    1 * @ui.print_line(tmp.path)
    1 * @ui.print_line("subprocess output")
    1 * @ui.done

    Cleanup
    tmp.unlink
  end

  test "run spawns subprocess with args passed through" do
    Given "a non-repl command with args"
    tmp = Tempfile.new(["test", ".sh"])
    tmp.write("#!/bin/sh\necho \"args: $@\"")
    tmp.close
    File.chmod(0o755, tmp.path)
    cmd = Dev::Command.new(run: tmp.path, repl: false)
    expected_shell_command = "#{tmp.path} --verbose"
    @ui.stubs(:print_line)
    @ui.stubs(:done)

    When "we run the command with args"
    @runner.run(cmd, args: ["--verbose"])

    Then "print_line is called for the command header and subprocess output"
    1 * @ui.print_line(expected_shell_command)
    1 * @ui.print_line("args: --verbose")
    1 * @ui.done

    Cleanup
    tmp.unlink
  end

  test "run raises when subprocess fails" do
    Given "a command that exits with non-zero status"
    tmp = Tempfile.new(["test", ".sh"])
    tmp.write("#!/bin/sh\nexit 1")
    tmp.close
    File.chmod(0o755, tmp.path)
    cmd = Dev::Command.new(run: tmp.path, repl: false)
    @ui.stubs(:print_line)

    When "we run the command"
    err = assert_raises(RuntimeError) { @runner.run(cmd) }

    Then "the error message includes the command path"
    assert_includes err.message, tmp.path

    Cleanup
    tmp.unlink
  end

  test "run parses protocol markers from subprocess output" do
    Given "a non-repl command that outputs protocol markers"
    tmp = Tempfile.new(["test", ".sh"])
    tmp.write("#!/bin/sh\necho '::ok::step one'\necho '::fail::step two'")
    tmp.close
    File.chmod(0o755, tmp.path)
    cmd = Dev::Command.new(run: tmp.path, repl: false)
    @ui.stubs(:print_line)
    @ui.stubs(:done)

    When "we run the command"
    @runner.run(cmd)

    Then "ok and fail are dispatched to the ui"
    1 * @ui.ok("step one")
    1 * @ui.fail("step two")

    Cleanup
    tmp.unlink
  end
end
