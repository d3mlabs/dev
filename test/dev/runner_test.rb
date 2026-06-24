# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev"
require "dev/runner"
require "dev/credentials"
require "dev/deps/cmake_integration"
require "stringio"
require "tempfile"
require "tmpdir"
require "fileutils"

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

  test "run with unknown command prints error to stderr and exits 1" do
    Given "a Runner"
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

  test "host integrations register a project-rooted cmake integration" do
    Given "a Runner"
    runner = build_runner
    root = Pathname.new(Dir.mktmpdir("runner-cmake-test-"))

    When "we build the host integrations for a project root"
    integrations = runner.send(:build_host_integrations, project_root: root)

    Then "the cmake integration is registered so dev install-deps fetches cmake source"
    integrations[:cmake].is_a?(Dev::Deps::CmakeIntegration)

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "up resolves docker build arg credentials before executing" do
    Given "a Runner with build container build_args and an up command"
    runner = build_runner(
      commands: { "up" => { "run" => "./bin/up.rb", "desc" => "Setup", "container" => false } },
      build: { "container" => {
        "image" => "myapp-linux", "registry" => "myregistry",
        "build_args" => { "WWISE_EMAIL" => "wwise/email" },
      } },
    )
    Dev::ShellCommand.any_instance.stubs(:execute)

    When "we run up"
    runner.run(["up"], ui: fake_ui)

    Then "build args are resolved (prompting and storing on first run)"
    1 * Dev::Credentials.resolve_build_args({ "WWISE_EMAIL" => "wwise/email" })
  end

  test "up without build container skips credential provisioning" do
    Given "a Runner without a build container"
    runner = build_runner(commands: { "up" => { "run" => "./bin/up.rb", "desc" => "Setup" } })
    Dev::ShellCommand.any_instance.stubs(:execute)

    When "we run up"
    runner.run(["up"], ui: fake_ui)

    Then "credentials are never resolved"
    0 * Dev::Credentials.resolve_build_args(anything)
  end

  test "non-up commands do not provision credentials eagerly" do
    Given "a Runner with build container build_args and a test command"
    runner = build_runner(
      commands: { "test" => { "run" => "./bin/test.sh", "desc" => "Run tests", "container" => false } },
      build: { "container" => {
        "image" => "myapp-linux", "registry" => "myregistry",
        "build_args" => { "WWISE_EMAIL" => "wwise/email" },
      } },
    )
    Dev::ShellCommand.any_instance.stubs(:execute)

    When "we run a non-up command"
    runner.run(["test"], ui: fake_ui)

    Then "credentials are not resolved eagerly"
    0 * Dev::Credentials.resolve_build_args(anything)
  end

  private

  def build_runner(name: "testproject", commands: {}, build: nil)
    yaml = { "name" => name, "ruby" => "4.0.1", "commands" => commands }
    yaml["build"] = build if build
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(YAML.dump(yaml))
    tmp.flush

    Dev::Runner.new(
      dev_yaml_path: Pathname.new(tmp.path),
      cfg_parser: Dev::ConfigParser.new(command_parser: Dev::CommandParser.new),
    )
  end

  def fake_ui
    ui = typed_mock(Dev::Cli::Ui)
    ui.stubs(:print_header)
    ui
  end
end
