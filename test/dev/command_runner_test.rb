# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command_runner"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class CommandRunnerTest < Minitest::Test
  extend T::Sig

  test "run with TTY and non-interactive uses frame and calls execute with in_frame true" do
    Given "a runner with a ruby script that exists and execute stubbed"
    runner = Dev::CommandRunner.new(root: root, interactive: false)
    tmp_file = TempFile.new("test.rb").tap do |f|
      f.write("puts 'ok'")
      f.flush
    end

    When "we run the script"
    runner = Dev::CommandRunner.new(root: root, interactive: false)

    Dir.mktmpdir do |root|
      bin = File.join(root, "bin")
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "test.rb"), "puts 'ok'")
      runner = Dev::CommandRunner.new(root: root, interactive: false)
      runner.stubs(:tty?).returns(true)
      executed = []
      runner.stubs(:execute).with do |script_path, in_frame:|
        executed << { script_path: script_path, in_frame: in_frame }
        true
      end

      When "we run with that script"
      runner.run(cmd_name: "test", run_str: "./bin/test.rb", args: [])

      Then "execute was called with resolved path and in_frame true"
      assert_equal 1, executed.size
      assert_equal true, executed[0][:in_frame]
      assert_equal File.expand_path("bin/test.rb", root), executed[0][:script_path]
    end
  end

  test "run when interactive uses run_without_frame" do
    Given "a runner with interactive true and execute stubbed"
    Dir.mktmpdir do |root|
      runner = Dev::CommandRunner.new(root: root, interactive: true)
      executed = []
      runner.stubs(:execute).with do |_script_path, in_frame:|
        executed << { in_frame: in_frame }
        true
      end

      When "we run"
      runner.run(cmd_name: "console", run_str: "./bin/console", args: [])

      Then "execute was called with in_frame false"
      assert_equal 1, executed.size
      assert_equal false, executed[0][:in_frame]
    end
  end

  test "run when not TTY uses run_without_frame" do
    Given "a runner with interactive false but not a TTY"
    Dir.mktmpdir do |root|
      runner = Dev::CommandRunner.new(root: root, interactive: false)
      runner.stubs(:tty?).returns(false)
      executed = []
      runner.stubs(:execute).with do |_script_path, in_frame:|
        executed << { in_frame: in_frame }
        true
      end

      When "we run"
      runner.run(cmd_name: "test", run_str: "bin/nonexistent.rb", args: [])

      Then "execute was called with in_frame false"
      assert_equal 1, executed.size
      assert_equal false, executed[0][:in_frame]
    end
  end

  test "run strips run_str before resolving" do
    Given "a runner with a script path that has leading space and exists"
    Dir.mktmpdir do |root|
      bin = File.join(root, "bin")
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "foo.rb"), "")
      runner = Dev::CommandRunner.new(root: root, interactive: true)
      runner.stubs(:execute)
      path_captured = nil
      runner.stubs(:execute).with do |script_path, in_frame:|
        path_captured = script_path
        true
      end

      When "we run with run_str that has leading/trailing space"
      runner.run(cmd_name: "foo", run_str: "  ./bin/foo.rb  ", args: [])

      Then "resolve uses stripped path and finds the script"
      assert_equal File.expand_path("bin/foo.rb", root), path_captured
    end
  end
end
