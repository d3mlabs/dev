# # typed: false
# # frozen_string_literal: true

# require "test_helper"
# require "dev"
# require "dev/runner"
# require "stringio"

# transform!(RSpock::AST::Transformation)
# class RunnerTest < Minitest::Test
#   extend T::Sig

#   def setup
#     @dev_yaml = <<~YAML
#       name: dev
#       commands:
#         up:
#           run: ./bin/up.rb
#     YAML
#     @cfg_parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
#     @ui = Dev::Cli::UiImpl.new(cli_ui: CLI::UI)
#   end

#   test "run with empty argv prints usage and returns" do
#     Given "a Runner and a dev.yml file"
#     tmp_file = Tempfile.new("dev.yml") do |f|
#       f.write(@dev_yaml)
#       f.flush
#     end
#     dev_yaml_path = Pathname.new(tmp_file.path)
#     runner = Dev::Runner.new(dev_yaml_path, cfg_parser: @cfg_parser, ui: @ui)
#     out = StringIO.new

#     When "we run with empty argv and injected out"
#     runner.run([], out: out)

#     Then "usage was written to the injected out"
#     1 * @cfg_parser.parse(dev_yaml_path)
#     1 * @ui.frame("Usage: dev <command> [args...]")
#     # assert_includes out.string, "Usage: dev <command> [args...]"
#     # assert_includes out.string, "Commands for"
#   end

#   test "run with --help prints usage and returns" do
#     Given "a Runner and an output buffer"
#     runner = Dev::Runner.new
#     out = StringIO.new

#     When "we run with --help and injected out"
#     runner.run(["--help"], out: out)

#     Then "usage was written to the injected out"
#     assert_includes out.string, "Usage: dev <command> [args...]"
#     assert_includes out.string, "Commands for"
#   end

#   test "run with -h prints usage and returns" do
#     Given "a Runner and an output buffer"
#     runner = Dev::Runner.new
#     out = StringIO.new

#     When "we run with -h and injected out"
#     runner.run(["-h"], out: out)

#     Then "usage was written to the injected out"
#     assert_includes out.string, "Usage: dev <command> [args...]"
#     assert_includes out.string, "Commands for"
#   end

#   test "run with unknown command prints error to stderr and exits 1" do
#     Given "a Runner and stderr captured"
#     runner = Dev::Runner.new
#     err = StringIO.new
#     old_stderr = $stderr
#     $stderr = err
#     Kernel.expects(:exit).with(1).once

#     When "we run an unknown command"
#     runner.run(["unknown-cmd"], out: StringIO.new)

#     Then "error was written to stderr"
#     assert_includes err.string, "unknown-cmd"
#     assert_includes err.string, "not defined"
#     assert_includes err.string, "dev --help"

#     Cleanup "restore stderr"
#     $stderr = old_stderr
#   end

#   test "run with valid command invokes CommandRunner with correct args" do
#     NOTE: Gotta change this to at least interaction-based testing.
#     Given "CommandRunner and Cli::Ui are stubbed"
#     command_runner_mock = mock
#     command_runner_mock.expects(:run).with(
#       cmd_name: "test",
#       run_str: "./bin/test.rb",
#       args: []
#     ).once
#     Dev::CommandRunner.stubs(:new).returns(command_runner_mock)

#     When "we run with a known command from dev.yml"
#     runner = Dev::Runner.new
#     runner.run(["test"])

#     Then "CommandRunner.run was invoked with cmd_name, run_str, and args from dev.yml"
#     assert true # Mocha verifies run was called once with correct args at teardown
#   end

#   test "show_usage? returns true for empty argv" do
#     Given "a Runner"
#     runner = Dev::Runner.new

#     When "we call show_usage? with empty argv"
#     result = runner.send(:show_usage?, [])

#     Then "it returns true"
#     assert result
#   end

#   test "show_usage? returns true for --help" do
#     Given "a Runner"
#     runner = Dev::Runner.new

#     When "we call show_usage? with [\"--help\"]"
#     result = runner.send(:show_usage?, ["--help"])

#     Then "it returns true"
#     assert result
#   end

#   test "show_usage? returns false for a command name" do
#     Given "a Runner"
#     runner = Dev::Runner.new

#     When "we call show_usage? with [\"test\"]"
#     result = runner.send(:show_usage?, ["test"])

#     Then "it returns false"
#     refute result
#   end

# end
