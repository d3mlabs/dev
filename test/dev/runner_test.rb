# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev"
require "dev/runner"
require "fileutils"
require "shadowenv_ruby"
require "stringio"
require "tempfile"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class RunnerTest < Minitest::Test
  extend T::Sig
  include SorbetHelper

  test "run with empty argv prints usage" do
    Given "a Runner with a dev.yml"
    out = StringIO.new
    runner = build_runner(commands: { "up" => { "run" => "./bin/up.rb", "desc" => "Setup" } }, out: out)

    When "we run with empty argv"
    runner.run([])

    Then "usage is printed"
    out.string.include?("Usage: dev <command> [args...]")
    out.string.include?("Commands for testproject:")
    out.string.include?("up")
    out.string.include?("Setup")
  end

  test "run with --help prints usage" do
    Given "a Runner"
    out = StringIO.new
    runner = build_runner(out: out)

    When "we run with --help"
    runner.run(["--help"])

    Then "usage is printed"
    out.string.include?("Usage: dev <command> [args...]")
  end

  test "run with -h prints usage" do
    Given "a Runner"
    out = StringIO.new
    runner = build_runner(out: out)

    When "we run with -h"
    runner.run(["-h"])

    Then "usage is printed"
    out.string.include?("Usage: dev <command> [args...]")
  end

  test "help is a command: dev help prints usage and lists itself" do
    Given "a Runner"
    out = StringIO.new
    runner = build_runner(out: out)

    When "we run the help command by name"
    runner.run(["help"])

    Then "usage is printed with help in the development flow section"
    out.string.include?("Usage: dev <command> [args...]")
    out.string.include?("help")
    out.string.include?("Show this usage")
  end

  test "usage renders the grouped sections" do
    Given "a Runner with a project command"
    out = StringIO.new
    runner = build_runner(commands: { "test" => { "run" => "rspec", "desc" => "Run tests" } }, out: out)

    When "we print usage"
    runner.run([])

    Then "the three sections render in order"
    lines = out.string.lines.map(&:chomp)
    lines.index("Commands for testproject:") < lines.index("Lifecycle:")
    lines.index("Lifecycle:") < lines.index("Development flow:")
  end

  test "run with unknown command prints error to stderr and exits 1" do
    Given "a Runner"
    runner = build_runner
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "we run an unknown command"
    runner.run(["nonexistent"])

    Then "error mentions the command name"
    $stderr.string.include?("nonexistent")
    $stderr.string.include?("dev --help")

    Cleanup
    $stderr = old_stderr
  end

  test "usage includes built-in update-deps command" do
    Given "a Runner with no project commands"
    out = StringIO.new
    runner = build_runner(commands: {}, out: out)

    When "we print usage"
    runner.run([])

    Then "update-deps is listed"
    out.string.include?("update-deps")
    out.string.include?("Resolve dependency constraints")
  end

  test "usage includes both built-in and project commands" do
    Given "a Runner with project commands"
    out = StringIO.new
    runner = build_runner(commands: {
      "test" => { "run" => "rspec", "desc" => "Run tests" },
      "up" => { "run" => "./bin/up.rb", "desc" => "Setup" },
    }, out: out)

    When "we print usage"
    runner.run([])

    Then "all commands appear"
    out.string.include?("update-deps")
    out.string.include?("test")
    out.string.include?("up")
  end

  test "up is a builtin even when the project defines no up command" do
    Given "a Runner with no project commands"
    out = StringIO.new
    runner = build_runner(commands: {}, out: out)

    When "we print usage"
    runner.run([])

    Then "up is listed as the builtin dependency install"
    out.string.include?("up")
    out.string.include?("Install locked dependencies, then run the project's up command")
  end

  test "a project up command keeps the builtin slot's section with its own desc" do
    Given "a Runner whose dev.yml overrides up"
    out = StringIO.new
    runner = build_runner(commands: { "up" => { "run" => "./bin/up.rb", "desc" => "Project setup" } }, out: out)

    When "we print usage"
    runner.run([])

    Then "the override's description wins"
    out.string.include?("Project setup")
    !out.string.include?("Install locked dependencies, then run the project's up command")
  end

  test "usage includes the cd builtin" do
    Given "a Runner with no project commands"
    out = StringIO.new
    runner = build_runner(commands: {}, out: out)

    When "we print usage"
    runner.run([])

    Then "cd is listed"
    out.string.include?("cd")
    out.string.include?("Jump to a checkout")
  end

  test "usage includes the clone builtin" do
    Given "a Runner with no project commands"
    out = StringIO.new
    runner = build_runner(commands: {}, out: out)

    When "we print usage"
    runner.run([])

    Then "clone is listed"
    out.string.include?("clone")
    out.string.include?("Clone a GitHub repo")
  end

  test "usage includes reset-container when the build container persists" do
    Given "a Runner whose build container opts into persist"
    out = StringIO.new
    runner = build_runner(
      commands: {},
      build: { "container" => {
        "image" => "myapp-linux", "registry" => "myregistry", "persist" => true,
      } },
      out: out,
    )

    When "we print usage"
    runner.run([])

    Then "the teardown command is listed"
    out.string.include?("reset-container")
  end

  test "reset-container is not registered without persist" do
    Given "a Runner with a non-persistent build container"
    out = StringIO.new
    runner = build_runner(
      commands: {},
      build: { "container" => { "image" => "myapp-linux", "registry" => "myregistry" } },
      out: out,
    )

    When "we print usage"
    runner.run([])

    Then "no teardown command is listed"
    !out.string.include?("reset-container")
  end

  test "provide-image is registered (but hidden) when a build container is configured" do
    Given "a Runner with a build container"
    usage = StringIO.new
    runner = build_runner(
      commands: {},
      build: { "container" => { "image" => "myapp-linux", "registry" => "myregistry" } },
      out: usage,
    )
    BuildContainer.stubs(:ensure_image!).returns("myregistry/myapp-linux:content-abc123")
    old_stdout = $stdout
    $stdout = StringIO.new

    When "we print usage and then invoke the command anyway"
    runner.run([])
    runner.run(["provide-image"])

    Then "the command is callable but omitted from usage"
    !usage.string.include?("provide-image")
    $stdout.string.include?("myregistry/myapp-linux:content-abc123")

    Cleanup
    $stdout = old_stdout
  end

  test "provide-image is not registered without a build container" do
    Given "a Runner without a build container"
    runner = build_runner(commands: {})
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "we invoke the absent command"
    runner.run(["provide-image"])

    Then "it is not found"
    $stderr.string.include?("provide-image")

    Cleanup
    $stderr = old_stderr
  end

  test "usage includes runner-setup when a runner block is declared" do
    Given "a Runner whose dev.yml declares a runner block"
    out = StringIO.new
    runner = build_runner(commands: {}, runner: { "labels" => "ue-engine" }, out: out)

    When "we print usage"
    runner.run([])

    Then "the runner-setup command is listed"
    out.string.include?("runner-setup")
  end

  test "runner-setup is not registered without a runner block" do
    Given "a Runner with no runner block"
    out = StringIO.new
    runner = build_runner(commands: {}, out: out)

    When "we print usage"
    runner.run([])

    Then "no runner-setup command is listed"
    !out.string.include?("runner-setup")
  end

  test "run assembles the execution context and hands the command to the service" do
    Given "a Runner over an expecting command service, with a declared toolchain"
    root = Pathname.new(Dir.mktmpdir("runner-context-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define do
        ruby "9.9.9"
        python "3.12"
      end
    RUBY
    contexts = []
    command_service = typed_mock(Dev::CommandService)
    command_service.stubs(:execute).with { |cmd_name, args:, context:|
      contexts << [cmd_name, args, context]
      true }
    ui = fake_ui
    runner = build_runner(commands: {}, command_service: command_service, ui: ui, root: root)
    ShadowenvRuby.stubs(:resolve_ruby_version).with("9.9.9").returns("9.9.9")

    When "we run a command with args"
    runner.run(["test", "--fast"])

    Then "the service got the name, args, and a fully-assembled context"
    cmd_name, args, context = contexts.fetch(0)
    cmd_name == "test"
    args == ["--fast"]
    context.ui == ui
    context.ruby_version == "9.9.9"
    context.python_version == "3.12"
    context.project_root == root

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a failed waited child exits with the child's status" do
    Given "a Runner whose service raises the child's failure"
    command_service = typed_mock(Dev::CommandService)
    command_service.stubs(:execute).raises(Dev::CommandRunner::CommandFailedError.new(exit_status: 7))
    runner = build_runner(commands: {}, command_service: command_service)
    Kernel.expects(:exit).with(7).once

    When "we run the command"
    runner.run(["up"])

    Then "the expectation on the exit mapping holds"
    true
  end

  test "an ArgumentError is reported as a clean dev error with exit 1" do
    Given "a Runner whose service raises a usage error"
    command_service = typed_mock(Dev::CommandService)
    command_service.stubs(:execute).raises(ArgumentError.new("usage: dev cache gc [--keep N]"))
    runner = build_runner(commands: {}, command_service: command_service)
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "we run the command"
    runner.run(["cache"])

    Then "the message reaches stderr under the dev: prefix"
    $stderr.string.include?("dev: usage: dev cache gc [--keep N]")

    Cleanup
    $stderr = old_stderr
  end

  test "an unmapped error is a dev bug and re-raises with its backtrace" do
    Given "a Runner whose service raises an unmapped error class"
    command_service = typed_mock(Dev::CommandService)
    command_service.stubs(:execute).raises(Dev::Deps::Cache::CacheMissError.new("no entry"))
    runner = build_runner(commands: {}, command_service: command_service)

    When "we run the command"
    runner.run(["deps"])

    Then
    raises Dev::Deps::Cache::CacheMissError
  end

  private

  # Every run builds an ExecutionContext (the toolchain pass is eager now),
  # so the helper always pins the project root to a temp dir and stubs the
  # ruby resolution; tests needing specific toolchain behavior re-stub after
  # (mocha matches the latest stub first) or pass their own root.
  def build_runner(name: "testproject", commands: {}, build: nil, runner: nil, command_service: nil,
    ui: fake_ui, out: StringIO.new, root: nil)
    root ||= (@tmp_roots ||= []).push(Pathname.new(Dir.mktmpdir("runner-test-"))).fetch(-1)
    Dev.stubs(:target_project_root).returns(root)
    ShadowenvRuby.stubs(:resolve_ruby_version).returns("4.0.1")

    yaml = { "name" => name, "commands" => commands }
    yaml["build"] = build if build
    yaml["runner"] = runner if runner
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(YAML.dump(yaml))
    tmp.flush

    Dev::Runner.new(dev_yaml_path: Pathname.new(tmp.path), ui: ui, out: out, command_service: command_service)
  end

  def teardown
    @tmp_roots&.each { |root| FileUtils.rm_rf(root) }
    super
  end

  def fake_ui
    ui = typed_mock(Dev::Cli::Ui)
    ui.stubs(:print_header)
    ui
  end
end
