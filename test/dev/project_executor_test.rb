# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/project_executor"
require "dev/command"
require "shadowenv_ruby"
require "fileutils"
require "pathname"
require "tmpdir"

# The one suite that exercises the Kernel.exec / Kernel.system process
# boundary: exec_into's tail-call shape, run_waiting's spawn-and-wait
# shape, and the failure paths of each.
transform!(RSpock::AST::Transformation)
class Dev::ProjectExecutorTest < Minitest::Test
  include SorbetHelper

  def build_context(project_root)
    ui = typed_mock(Dev::Cli::Ui)
    ui.stubs(:print_header)
    Dev::ExecutionContext.new(ui: ui, ruby_version: "4.0.1", project_root: project_root)
  end

  test "exec_into keeps the exec tail-call, never spawn-and-wait" do
    Given "a project command, pinned to an empty project root"
    original_cwd = Dir.pwd
    root = Pathname.new(Dir.mktmpdir("project-executor-exec-"))
    command = Dev::ProjectCommand.new(run: "./bin/test.sh", desc: "Run tests", container: false)
    executor = Dev::ProjectExecutor.new
    # Provisioning's shell-out boundary; llvm/python provisioning no-op on
    # an empty project root.
    ShadowenvRuby.stubs(:ensure!)

    When "exec_into runs (the stubbed exec returns, so the honesty guard raises)"
    error = nil
    begin
      executor.exec_into(command, args: [], context: build_context(root))
    rescue Dev::ProjectExecutor::ExecReturnedError => e
      error = e
    end

    Then "the command exec-replaced the process, never spawn-and-wait"
    1 * Kernel.exec(anything, "shadowenv", "exec", "--", "sh", "-c", includes("./bin/test.sh"))
    0 * Kernel.system(any_parameters)
    !error.nil?

    Cleanup
    Dir.chdir(original_cwd)
    FileUtils.rm_rf(root)
  end

  test "exec_into forwards its args into the child's shell command" do
    Given "a project command executed with args"
    original_cwd = Dir.pwd
    root = Pathname.new(Dir.mktmpdir("project-executor-args-"))
    command = Dev::ProjectCommand.new(run: "./bin/test.sh", desc: "Run tests", container: false)
    executor = Dev::ProjectExecutor.new
    ShadowenvRuby.stubs(:ensure!)

    When "exec_into runs with args"
    begin
      executor.exec_into(command, args: ["--fast", "spec/a"], context: build_context(root))
    rescue Dev::ProjectExecutor::ExecReturnedError
      # Expected under a stubbed exec boundary; the argv assertion below is
      # the point of this test.
    end

    Then "the args are shell-joined onto the run string"
    1 * Kernel.exec(anything, "shadowenv", "exec", "--", "sh", "-c", includes("./bin/test.sh --fast spec/a"))

    Cleanup
    Dir.chdir(original_cwd)
    FileUtils.rm_rf(root)
  end

  test "a faked-out exec boundary raises ExecReturnedError" do
    Given "an exec boundary that returns control instead of replacing the process"
    original_cwd = Dir.pwd
    root = Pathname.new(Dir.mktmpdir("project-executor-exec-returned-"))
    command = Dev::ProjectCommand.new(run: "./bin/test.sh", desc: "Run tests", container: false)
    executor = Dev::ProjectExecutor.new
    ShadowenvRuby.stubs(:ensure!)
    Kernel.stubs(:exec)

    When "exec_into runs"
    executor.exec_into(command, args: [], context: build_context(root))

    Then "the never-returns contract raises"
    raises Dev::ProjectExecutor::ExecReturnedError

    Cleanup
    Dir.chdir(original_cwd)
    FileUtils.rm_rf(root)
  end

  test "run_waiting spawns and waits, returning control on success" do
    Given "a project command over a succeeding child, pinned to an empty project root"
    original_cwd = Dir.pwd
    root = Pathname.new(Dir.mktmpdir("project-executor-wait-"))
    command = Dev::ProjectCommand.new(run: "./bin/up.rb", desc: "Setup", container: false)
    executor = Dev::ProjectExecutor.new
    ShadowenvRuby.stubs(:ensure!)
    # The wait-mode execution boundary is Kernel.system; record its argv.
    child_argvs = []
    Kernel.stubs(:system).with { |*argv|
      child_argvs << argv
      true }.returns(true)

    When "run_waiting runs"
    executor.run_waiting(command, args: [], context: build_context(root))

    Then "the child was a waited spawn of the shell wrapper, never exec-replace"
    child_argvs.size == 1
    child_argvs.fetch(0)[1..5] == ["shadowenv", "exec", "--", "sh", "-c"]
    child_argvs.fetch(0).fetch(6).include?("./bin/up.rb")
    0 * Kernel.exec(any_parameters)

    Cleanup
    Dir.chdir(original_cwd)
    FileUtils.rm_rf(root)
  end

  test "a failing waited child raises CommandFailedError with the child's status" do
    Given "a project command whose child exits 7"
    original_cwd = Dir.pwd
    root = Pathname.new(Dir.mktmpdir("project-executor-wait-fail-"))
    command = Dev::ProjectCommand.new(run: "./bin/up.rb", desc: "Setup", container: false)
    executor = Dev::ProjectExecutor.new
    ShadowenvRuby.stubs(:ensure!)
    Kernel.stubs(:system).returns(false)
    # Kernel.system is stubbed, so wait on a real child here to leave the
    # thread-local $? at exit status 7 — what a real failed child would set.
    Process.wait(Process.spawn("sh", "-c", "exit 7"))
    # Guard: a regression to exec-replace would otherwise replace the test
    # process itself (Kernel.system above is stubbed, Kernel.exec is real).
    Kernel.expects(:exec).never

    When "run_waiting runs"
    error = nil
    begin
      executor.run_waiting(command, args: [], context: build_context(root))
    rescue Dev::CommandRunner::CommandFailedError => e
      error = e
    end

    Then "the child's exit status rides the error"
    error.exit_status == 7

    Cleanup
    Dir.chdir(original_cwd)
    FileUtils.rm_rf(root)
  end
end
