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
    runner = build_runner(commands: { "up" => { "run" => "./bin/up.rb", "desc" => "Setup" } })
    out = StringIO.new

    When "we run with empty argv"
    runner.run([], ui: fake_ui, out: out)

    Then "usage is printed"
    out.string.include?("Usage: dev <command> [args...]")
    out.string.include?("Commands for testproject:")
    out.string.include?("up")
    out.string.include?("Setup")
  end

  test "run with --help prints usage" do
    Given "a Runner"
    runner = build_runner
    out = StringIO.new

    When "we run with --help"
    runner.run(["--help"], ui: fake_ui, out: out)

    Then "usage is printed"
    out.string.include?("Usage: dev <command> [args...]")
  end

  test "run with -h prints usage" do
    Given "a Runner"
    runner = build_runner
    out = StringIO.new

    When "we run with -h"
    runner.run(["-h"], ui: fake_ui, out: out)

    Then "usage is printed"
    out.string.include?("Usage: dev <command> [args...]")
  end

  test "usage never loads the deps manifest (dev --help stays lazy)" do
    Given "a Runner whose project root carries a booby-trapped dependencies.rb"
    root = Pathname.new(Dir.mktmpdir("runner-usage-lazy-"))
    File.write(root / "dependencies.rb", "raise 'usage must not load me'\n")
    Dev.stubs(:target_project_root).returns(root)
    runner = build_runner
    out = StringIO.new

    When "we print usage"
    runner.run([], ui: fake_ui, out: out)

    Then "the usage rendered without touching dependencies.rb"
    out.string.include?("Usage: dev <command> [args...]")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "run with unknown command prints error to stderr and exits 1" do
    Given "a Runner pinned to an empty project root"
    root = Pathname.new(Dir.mktmpdir("runner-unknown-"))
    Dev.stubs(:target_project_root).returns(root)
    ShadowenvRuby.stubs(:resolve_ruby_version).returns("4.0.1")
    runner = build_runner
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "we run an unknown command"
    runner.run(["nonexistent"], ui: fake_ui)

    Then "error mentions the command name"
    $stderr.string.include?("nonexistent")
    $stderr.string.include?("dev --help")

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(root)
  end

  test "usage includes built-in update-deps command" do
    Given "a Runner with no project commands"
    runner = build_runner(commands: {})
    out = StringIO.new

    When "we print usage"
    runner.run([], ui: fake_ui, out: out)

    Then "update-deps is listed"
    out.string.include?("update-deps")
    out.string.include?("Resolve dependency constraints")
  end

  test "usage includes both built-in and project commands" do
    Given "a Runner with project commands"
    runner = build_runner(commands: {
      "test" => { "run" => "rspec", "desc" => "Run tests" },
      "up" => { "run" => "./bin/up.rb", "desc" => "Setup" },
    })
    out = StringIO.new

    When "we print usage"
    runner.run([], ui: fake_ui, out: out)

    Then "all commands appear"
    out.string.include?("update-deps")
    out.string.include?("test")
    out.string.include?("up")
  end

  test "up is a builtin even when the project defines no up command" do
    Given "a Runner with no project commands"
    runner = build_runner(commands: {})
    out = StringIO.new

    When "we print usage"
    runner.run([], ui: fake_ui, out: out)

    Then "up is listed as the builtin dependency install"
    out.string.include?("up")
    out.string.include?("Install locked dependencies, then run the project's up command")
  end

  test "a project up command keeps the builtin slot's position with its own desc" do
    Given "a Runner whose dev.yml overrides up"
    runner = build_runner(commands: { "up" => { "run" => "./bin/up.rb", "desc" => "Project setup" } })
    out = StringIO.new

    When "we print usage"
    runner.run([], ui: fake_ui, out: out)

    Then "the override's description wins"
    out.string.include?("Project setup")
    !out.string.include?("Install locked dependencies, then run the project's up command")
  end

  test "usage includes the cd builtin" do
    Given "a Runner with no project commands"
    runner = build_runner(commands: {})
    out = StringIO.new

    When "we print usage"
    runner.run([], ui: fake_ui, out: out)

    Then "cd is listed"
    out.string.include?("cd")
    out.string.include?("Jump to a checkout")
  end

  test "usage includes the clone builtin" do
    Given "a Runner with no project commands"
    runner = build_runner(commands: {})
    out = StringIO.new

    When "we print usage"
    runner.run([], ui: fake_ui, out: out)

    Then "clone is listed"
    out.string.include?("clone")
    out.string.include?("Clone a GitHub repo")
  end

  test "usage includes reset-container when the build container persists" do
    Given "a Runner whose build container opts into persist"
    runner = build_runner(
      commands: {},
      build: { "container" => {
        "image" => "myapp-linux", "registry" => "myregistry", "persist" => true,
      } },
    )
    out = StringIO.new

    When "we print usage"
    runner.run([], ui: fake_ui, out: out)

    Then "the teardown command is listed"
    out.string.include?("reset-container")
  end

  test "reset-container is not registered without persist" do
    Given "a Runner with a non-persistent build container"
    runner = build_runner(
      commands: {},
      build: { "container" => { "image" => "myapp-linux", "registry" => "myregistry" } },
    )
    out = StringIO.new

    When "we print usage"
    runner.run([], ui: fake_ui, out: out)

    Then "no teardown command is listed"
    !out.string.include?("reset-container")
  end

  test "provide-image is registered (but hidden) when a build container is configured" do
    Given "a Runner with a build container, pinned to an empty project root"
    root = Pathname.new(Dir.mktmpdir("runner-provide-image-"))
    Dev.stubs(:target_project_root).returns(root)
    ShadowenvRuby.stubs(:resolve_ruby_version).returns("4.0.1")
    runner = build_runner(
      commands: {},
      build: { "container" => { "image" => "myapp-linux", "registry" => "myregistry" } },
    )
    BuildContainer.stubs(:ensure_image!).returns("myregistry/myapp-linux:content-abc123")
    usage = StringIO.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "we print usage and then invoke the command anyway"
    runner.run([], ui: fake_ui, out: usage)
    runner.run(["provide-image"], ui: fake_ui)

    Then "the command is callable but omitted from usage"
    !usage.string.include?("provide-image")
    $stdout.string.include?("myregistry/myapp-linux:content-abc123")

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "provide-image is not registered without a build container" do
    Given "a Runner without a build container, pinned to an empty project root"
    root = Pathname.new(Dir.mktmpdir("runner-no-provide-image-"))
    Dev.stubs(:target_project_root).returns(root)
    ShadowenvRuby.stubs(:resolve_ruby_version).returns("4.0.1")
    runner = build_runner(commands: {})
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "we invoke the absent command"
    runner.run(["provide-image"], ui: fake_ui)

    Then "it is not found"
    $stderr.string.include?("provide-image")

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(root)
  end

  test "usage includes runner-setup when a runner block is declared" do
    Given "a Runner whose dev.yml declares a runner block"
    runner = build_runner(commands: {}, runner: { "labels" => "ue-engine" })
    out = StringIO.new

    When "we print usage"
    runner.run([], ui: fake_ui, out: out)

    Then "the runner-setup command is listed"
    out.string.include?("runner-setup")
  end

  test "runner-setup is not registered without a runner block" do
    Given "a Runner with no runner block"
    runner = build_runner(commands: {})
    out = StringIO.new

    When "we print usage"
    runner.run([], ui: fake_ui, out: out)

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
    Dev.stubs(:target_project_root).returns(root)
    ShadowenvRuby.stubs(:resolve_ruby_version).with("9.9.9").returns("9.9.9")
    contexts = []
    command_service = typed_mock(Dev::CommandService)
    command_service.stubs(:execute).with { |cmd_name, args:, context:|
      contexts << [cmd_name, args, context]
      true }
    runner = build_runner(commands: {}, command_service: command_service)
    ui = fake_ui

    When "we run a command with args"
    runner.run(["test", "--fast"], ui: ui)

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
    root = Pathname.new(Dir.mktmpdir("runner-exit-map-"))
    Dev.stubs(:target_project_root).returns(root)
    ShadowenvRuby.stubs(:resolve_ruby_version).returns("4.0.1")
    command_service = typed_mock(Dev::CommandService)
    command_service.stubs(:execute).raises(Dev::CommandRunner::CommandFailedError.new(exit_status: 7))
    runner = build_runner(commands: {}, command_service: command_service)
    Kernel.expects(:exit).with(7).once

    When "we run the command"
    runner.run(["up"], ui: fake_ui)

    Then "the expectation on the exit mapping holds"
    true

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "an ArgumentError is reported as a clean dev error with exit 1" do
    Given "a Runner whose service raises a usage error"
    root = Pathname.new(Dir.mktmpdir("runner-argerror-"))
    Dev.stubs(:target_project_root).returns(root)
    ShadowenvRuby.stubs(:resolve_ruby_version).returns("4.0.1")
    command_service = typed_mock(Dev::CommandService)
    command_service.stubs(:execute).raises(ArgumentError.new("usage: dev cache gc [--keep N]"))
    runner = build_runner(commands: {}, command_service: command_service)
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "we run the command"
    runner.run(["cache"], ui: fake_ui)

    Then "the message reaches stderr under the dev: prefix"
    $stderr.string.include?("dev: usage: dev cache gc [--keep N]")

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(root)
  end

  test "an unmapped error is a dev bug and re-raises with its backtrace" do
    Given "a Runner whose service raises an unmapped error class"
    root = Pathname.new(Dir.mktmpdir("runner-unmapped-"))
    Dev.stubs(:target_project_root).returns(root)
    ShadowenvRuby.stubs(:resolve_ruby_version).returns("4.0.1")
    command_service = typed_mock(Dev::CommandService)
    command_service.stubs(:execute).raises(Dev::Deps::Cache::CacheMissError.new("no entry"))
    runner = build_runner(commands: {}, command_service: command_service)

    When "we run the command"
    runner.run(["deps"], ui: fake_ui)

    Then
    raises Dev::Deps::Cache::CacheMissError

    Cleanup
    FileUtils.rm_rf(root)
  end

  private

  def build_runner(name: "testproject", commands: {}, build: nil, runner: nil, command_service: nil)
    yaml = { "name" => name, "commands" => commands }
    yaml["build"] = build if build
    yaml["runner"] = runner if runner
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(YAML.dump(yaml))
    tmp.flush

    Dev::Runner.new(dev_yaml_path: Pathname.new(tmp.path), command_service: command_service)
  end

  def fake_ui
    ui = typed_mock(Dev::Cli::Ui)
    ui.stubs(:print_header)
    ui
  end
end
