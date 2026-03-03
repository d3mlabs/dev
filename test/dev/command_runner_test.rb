# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command_runner"

transform!(RSpock::AST::Transformation)
class CommandRunnerTest < Minitest::Test
  extend T::Sig
  include SorbetHelper

  def setup
    @ui = typed_mock(Dev::Cli::Ui)
    @ui.stubs(:print_header)
    @runner = Dev::CommandRunner.new(ui: @ui, ruby_version: "4.0.1")
    @runner.stubs(:ensure_shadowenv_provisioned!)
  end

  test "run prints header and execs directly when repl" do
    Given "a repl command"
    cmd = Dev::Command.new(run: "./bin/console", repl: true)

    When "we run the command"
    @runner.run(cmd)

    Then "header is printed and process is replaced via exec"
    1 * @ui.print_header("./bin/console")
    1 * Kernel.exec({"GEM_HOME" => nil}, "shadowenv", "exec", "--", "sh", "-c", "./bin/console")
  end

  test "run prints header and execs with args when repl" do
    Given "a repl command with args"
    cmd = Dev::Command.new(run: "./bin/console", repl: true)

    When "we run the command with extra args"
    @runner.run(cmd, args: ["--verbose"])

    Then "header includes args and exec passes them through"
    1 * @ui.print_header("./bin/console --verbose")
    1 * Kernel.exec({"GEM_HOME" => nil}, "shadowenv", "exec", "--", "sh", "-c", "./bin/console --verbose")
  end

  test "run prints header and execs with shell wrapper for non-repl" do
    Given "a non-repl command"
    cmd = Dev::Command.new(run: "./bin/setup.rb", repl: false)

    When "we run the command"
    @runner.run(cmd)

    Then "header is printed and exec is called with a shell wrapper"
    1 * @ui.print_header("./bin/setup.rb")
    1 * Kernel.exec({"GEM_HOME" => nil}, "shadowenv", "exec", "--", "sh", "-c", includes("./bin/setup.rb"))
  end

  test "non-repl shell wrapper includes status check and Done message" do
    Given "a non-repl command"
    cmd = Dev::Command.new(run: "./bin/test.sh", repl: false)

    When "we run the command"
    @runner.run(cmd)

    Then "the shell wrapper includes exit code handling and Done/Failed output"
    1 * Kernel.exec({"GEM_HOME" => nil}, "shadowenv", "exec", "--", "sh", "-c",
      all_of(includes("./bin/test.sh"), includes("__dev_status=$?"), includes("Done"), includes("Failed")))
  end

  test "non-repl shell wrapper includes args" do
    Given "a non-repl command with args"
    cmd = Dev::Command.new(run: "./bin/test.sh", repl: false)

    When "we run with args"
    @runner.run(cmd, args: ["-v"])

    Then "header and wrapper both include args"
    1 * @ui.print_header("./bin/test.sh -v")
    1 * Kernel.exec({"GEM_HOME" => nil}, "shadowenv", "exec", "--", "sh", "-c", includes("./bin/test.sh -v"))
  end
end
