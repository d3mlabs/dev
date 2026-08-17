# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command_executor"
require "dev/command"
require "shadowenv_ruby"
require "fileutils"
require "pathname"
require "tmpdir"

# Builtin fake for dispatch-order assertions; traits configurable so the
# override path can exercise both wait shapes.
class ExecutorFakeBuiltin < Dev::BuiltinCommand
  attr_reader :calls

  def initialize(stamps: false, &body)
    @stamps = stamps
    @calls = []
    @body = body
    super()
  end

  def desc = "a builtin"

  def stamps? = @stamps

  def call(args:, context:)
    @calls << [args, context]
    @body&.call
  end
end unless defined?(ExecutorFakeBuiltin)

transform!(RSpock::AST::Transformation)
class Dev::CommandExecutorTest < Minitest::Test
  include SorbetHelper

  def build_context(project_root)
    ui = typed_mock(Dev::Cli::Ui)
    ui.stubs(:print_header)
    Dev::ExecutionContext.new(ui: ui, ruby_version: "4.0.1", project_root: project_root)
  end

  test "a builtin command runs its Ruby body in-process" do
    Given "a builtin and an executor"
    builtin = ExecutorFakeBuiltin.new
    executor = Dev::CommandExecutor.new
    root = Pathname.new(Dir.mktmpdir("executor-builtin-"))
    context = build_context(root)

    When "executing"
    executor.execute(builtin, args: ["--verbose"], context: context)

    Then "the body received args and context; no child process was involved"
    builtin.calls == [[["--verbose"], context]]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a project command keeps the exec tail-call" do
    Given "a plain project command, pinned to an empty project root"
    original_cwd = Dir.pwd
    root = Pathname.new(Dir.mktmpdir("executor-exec-tail-"))
    command = Dev::ProjectCommand.new(run: "./bin/test.sh", desc: "Run tests", container: false)
    executor = Dev::CommandExecutor.new
    # Provisioning's shell-out boundary; llvm/python provisioning no-op on
    # an empty project root.
    ShadowenvRuby.stubs(:ensure!)

    When "executing a non-stamping command"
    executor.execute(command, args: [], context: build_context(root))

    Then "the command exec-replaces the process, never spawn-and-wait"
    1 * Kernel.exec(anything, "shadowenv", "exec", "--", "sh", "-c", includes("./bin/test.sh"))
    0 * Kernel.system(any_parameters)

    Cleanup
    Dir.chdir(original_cwd)
    FileUtils.rm_rf(root)
  end

  # Regression for dev#85: a project-defined `up:` used to exec-replace the
  # dev process, so the installed stamp after execute was never reached and
  # the staleness gate reported "never installed" forever.
  test "an overridden stamping slot runs the builtin first, then the project script spawn-and-wait" do
    Given "a stamping builtin slot overridden by a project up:, pinned to an empty project root"
    original_cwd = Dir.pwd
    root = Pathname.new(Dir.mktmpdir("executor-up-wait-"))
    execution_order = []
    builtin = ExecutorFakeBuiltin.new(stamps: true) { execution_order << :builtin_install }
    command = Dev::OverriddenCommand.new(
      builtin: builtin,
      project: Dev::ProjectCommand.new(run: "./bin/up.rb", desc: "Setup", container: false),
    )
    executor = Dev::CommandExecutor.new
    ShadowenvRuby.stubs(:ensure!)
    # The project script's execution boundary is Kernel.system (wait mode).
    Kernel.stubs(:system).with {
      execution_order << :project_script
      true }.returns(true)

    When "executing the overridden command"
    executor.execute(command, args: [], context: build_context(root))

    Then "builtin super() ran first, and the script was a waited child, never exec-replace"
    execution_order == [:builtin_install, :project_script]
    0 * Kernel.exec(any_parameters)

    Cleanup
    Dir.chdir(original_cwd)
    FileUtils.rm_rf(root)
  end

  test "a failing waited project script raises CommandFailedError with the child's status" do
    Given "an overridden stamping slot whose script exits 7"
    original_cwd = Dir.pwd
    root = Pathname.new(Dir.mktmpdir("executor-up-fail-"))
    command = Dev::OverriddenCommand.new(
      builtin: ExecutorFakeBuiltin.new(stamps: true),
      project: Dev::ProjectCommand.new(run: "./bin/up.rb", desc: "Setup", container: false),
    )
    executor = Dev::CommandExecutor.new
    ShadowenvRuby.stubs(:ensure!)
    Kernel.stubs(:system).returns(false)
    # Kernel.system is stubbed, so wait on a real child here to leave the
    # thread-local $? at exit status 7 — what a real failed child would set.
    Process.wait(Process.spawn("sh", "-c", "exit 7"))
    # Guard: a regression to exec-replace would otherwise replace the test
    # process itself (Kernel.system above is stubbed, Kernel.exec is real).
    Kernel.expects(:exec).never

    When "executing the overridden command"
    error = nil
    begin
      executor.execute(command, args: [], context: build_context(root))
    rescue Dev::CommandRunner::CommandFailedError => e
      error = e
    end

    Then "the child's exit status rides the error"
    error.exit_status == 7

    Cleanup
    Dir.chdir(original_cwd)
    FileUtils.rm_rf(root)
  end

  test "an overridden non-stamping slot keeps the exec tail-call for the project half" do
    Given "a non-stamping builtin slot overridden by a project command"
    original_cwd = Dir.pwd
    root = Pathname.new(Dir.mktmpdir("executor-override-exec-"))
    builtin = ExecutorFakeBuiltin.new(stamps: false)
    command = Dev::OverriddenCommand.new(
      builtin: builtin,
      project: Dev::ProjectCommand.new(run: "./bin/lint.sh", desc: "Lint", container: false),
    )
    executor = Dev::CommandExecutor.new
    ShadowenvRuby.stubs(:ensure!)

    When "executing"
    executor.execute(command, args: [], context: build_context(root))

    Then "nothing sequences after execute, so the exec tail-call is safe and kept"
    builtin.calls.size == 1
    1 * Kernel.exec(anything, "shadowenv", "exec", "--", "sh", "-c", includes("./bin/lint.sh"))
    0 * Kernel.system(any_parameters)

    Cleanup
    Dir.chdir(original_cwd)
    FileUtils.rm_rf(root)
  end

  test "a project command forwards its args into the child's shell command" do
    Given "a project command executed with args"
    original_cwd = Dir.pwd
    root = Pathname.new(Dir.mktmpdir("executor-args-"))
    command = Dev::ProjectCommand.new(run: "./bin/test.sh", desc: "Run tests", container: false)
    executor = Dev::CommandExecutor.new
    ShadowenvRuby.stubs(:ensure!)

    When "executing with args"
    executor.execute(command, args: ["--fast", "spec/a"], context: build_context(root))

    Then "the args are shell-joined onto the run string"
    1 * Kernel.exec(anything, "shadowenv", "exec", "--", "sh", "-c", includes("./bin/test.sh --fast spec/a"))

    Cleanup
    Dir.chdir(original_cwd)
    FileUtils.rm_rf(root)
  end
end
